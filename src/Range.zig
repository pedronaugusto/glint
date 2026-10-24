//! Integer ranges the flow rules read (designs/aegis.md §7): the least and the greatest value an
//! integer can have, from its type (a decode's spelled type, a typed local, field or parameter,
//! `@as` and a conversion's destination), from what an expression does to the ranges of its
//! operands, from what a constant, a local, a field or a function is given, and from the
//! comparisons that hold where it is read: the branch it is in, an earlier `if (end > buf.len)
//! return`, an `assert` it follows. A comparison relates two values (`a < b`, `a + k <= b`,
//! `b.len - a >= k`), and two of them combine (`a <= b`, `b <= c.len`).
//! A010 reads them to decide whether arithmetic on a peer's number can overflow its type, whether
//! a conversion of input can fail and whether a divisor can be zero; A009 reads them to decide
//! whether a position stays within its memory; the loop, table and work sinks read a number held
//! to 16 bits as data, as a decode of 16 bits is.
//!
//! A range is read at each pointer width a package may build for, 32 and 64 bits: `usize` is
//! as wide as the target's pointer and a slice's length one bit less, so a sum of two lengths
//! never overflows `usize` and a sum of a length and a decoded `u32` does on a 32-bit target.
//! A site is clear only where it is clear at both.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Contract = @import("AegisContract.zig");
const Project = @import("Project.zig");
const Taint = @import("Taint.zig");
const Ast = std.zig.Ast;

/// An integer type: its width, and whether it is signed.
pub const Int = struct {
    bits: u16,
    signed: bool,

    /// The greatest magnitude the type holds.
    fn room(self: Int) u128 {
        return filled(if (self.signed) self.bits -| 1 else self.bits);
    }

    /// The values the type holds.
    fn values(self: Int) Interval {
        if (self.bits > 128) return .any;
        const most: i132 = self.room();
        return if (self.signed) .{ .least = -most - 1, .most = most } else .{ .least = 0, .most = most };
    }
};

/// The values an integer can take, from `least` to `most`. A side the reading does not know
/// lies past every type's room, so the type the value is read in narrows it.
const Interval = struct {
    least: i132,
    most: i132,

    const far: i132 = 1 << 130;
    const any: Interval = .{ .least = -far, .most = far };

    fn exactly(value: i132) Interval {
        return .{ .least = value, .most = value };
    }

    /// What both hold: the values the two readings agree on.
    fn meet(a: Interval, b: Interval) Interval {
        return .{ .least = @max(a.least, b.least), .most = @min(a.most, b.most) };
    }

    /// What either holds.
    fn join(a: Interval, b: Interval) Interval {
        return .{ .least = @min(a.least, b.least), .most = @max(a.most, b.most) };
    }

    fn within(a: Interval, b: Interval) bool {
        return a.least >= b.least and a.most <= b.most;
    }

    fn empty(a: Interval) bool {
        return a.least > a.most;
    }

    /// The greatest magnitude a value can have.
    fn magnitude(a: Interval) u128 {
        return @intCast(@min(@max(@abs(a.least), @abs(a.most)), std.math.maxInt(u128)));
    }

    fn plus(a: Interval, b: Interval) Interval {
        return .{ .least = clamp(a.least +| b.least), .most = clamp(a.most +| b.most) };
    }

    fn minus(a: Interval, b: Interval) Interval {
        return .{ .least = clamp(a.least -| b.most), .most = clamp(a.most -| b.least) };
    }

    fn times(a: Interval, b: Interval) Interval {
        const corners = [_]i132{ a.least *| b.least, a.least *| b.most, a.most *| b.least, a.most *| b.most };
        var out: Interval = .{ .least = corners[0], .most = corners[0] };
        for (corners[1..]) |each| out = out.join(exactly(each));
        return .{ .least = clamp(out.least), .most = clamp(out.most) };
    }

    fn negated(a: Interval) Interval {
        return .{ .least = -a.most, .most = -a.least };
    }
};

fn clamp(value: i132) i132 {
    return std.math.clamp(value, -Interval.far, Interval.far);
}

/// What type an expression computes in: an integer type, a comptime number that takes the
/// other operand's, or one the reading does not know.
const Typed = union(enum) {
    int: Int,
    literal,
    unknown,

    /// Zig's peer type of two operands: the wider, signed where either is (and wide enough
    /// for the unsigned one).
    fn peer(a: Typed, b: Typed) Typed {
        if (a == .unknown or b == .unknown) return .unknown;
        if (a == .literal) return b;
        if (b == .literal) return a;
        const x = a.int;
        const y = b.int;
        if (x.signed == y.signed) return .{ .int = .{ .bits = @max(x.bits, y.bits), .signed = x.signed } };
        const signed = if (x.signed) x else y;
        const unsigned = if (x.signed) y else x;
        return .{ .int = .{ .bits = @max(signed.bits, unsigned.bits + 1), .signed = true } };
    }

    /// The values the type holds; any where it is not an integer type.
    fn values(self: Typed) Interval {
        return switch (self) {
            .int => |int| int.values(),
            else => .any,
        };
    }
};

/// The pointer widths a range is read at.
const pointers = [_]u16{ 32, 64 };
/// How deep one reading follows an expression's operands; what a constant, a local, a field or a
/// function gives is read once from its own depth.
const depth_limit = 24;

/// Whether arithmetic `node` (`+`, `*`, `-` and their assignments) cannot overflow its type
/// whatever its operands' ranges hold, at every pointer width, and an unsigned difference
/// cannot underflow.
pub fn fits(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const tag = tree.nodeTag(node);
    const assigns = switch (tag) {
        .assign_add, .assign_sub, .assign_mul => true,
        else => false,
    };
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    for (pointers) |pointer| {
        const typed = if (assigns) try typeOf(c, file, lhs, pointer, 0) else try typeOf(c, file, node, pointer, 0);
        const int = switch (typed) {
            .int => |int| int,
            else => return false,
        };
        // A remainder spelled out (`y - @divFloor(y, k) * k`) is below `k`.
        if (tag == .sub and try remainder(c, file, lhs, rhs) != null) continue;
        // A length less a position into its memory.
        if ((tag == .sub or tag == .assign_sub) and !int.signed and isLength(tree, lhs)) {
            if (try indexes(c, file, rhs, tree.nodeData(bare(tree, lhs)).node_and_token[0])) continue;
        }
        const raw = try refined(c, file, node, try operation(c, file, node, pointer, 0), pointer, 0);
        if (!raw.within(int.values())) return false;
    }
    return true;
}

/// Whether the conversion `node` (`@intCast(x)`) cannot fail: its destination holds every
/// value the operand's range does, at every pointer width.
pub fn converts(c: *Context, file: Project.FileId, node: Ast.Node.Index, operand: Ast.Node.Index) Context.Error!bool {
    for (pointers) |pointer| {
        const into = (try destination(c, file, node, pointer)) orelse return false;
        if (!(try bound(c, file, operand, pointer, 0)).within(into.values())) return false;
    }
    return true;
}

/// Whether division or a remainder `node` cannot fail on its divisor: the divisor is never
/// zero, nor -1 where that overflows, at every pointer width.
pub fn divides(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const rhs = c.project.files[file.raw()].tree.nodeData(node).node_and_node[1];
    for (pointers) |pointer| {
        const divisor = try bound(c, file, rhs, pointer, 0);
        if (divisor.least < 1 and divisor.most > -2) return false;
    }
    return true;
}

/// Whether a value is held to 16 bits at every pointer width: what it can be is a short's
/// count, never a peer's past it.
pub fn small(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    for (pointers) |pointer| {
        if ((try bound(c, file, node, pointer, 0)).magnitude() > std.math.maxInt(u16)) return false;
    }
    return true;
}

/// Each expression's range, read once per pointer width.
const Bounds = struct { map: std.AutoHashMapUnmanaged(struct { u32, u32, u16 }, Interval) = .empty };

/// The values an expression can take: what its operation gives, within its type, narrowed by
/// the comparisons that hold where it is read.
fn bound(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!Interval {
    if (depth > depth_limit) return .any;
    const memo = try c.facts.memo(Bounds);
    const key = .{ file.raw(), @backingInt(node), pointer };
    if (memo.map.get(key)) |known| return known;
    const typed = (try typeOf(c, file, node, pointer, depth)).values();
    // An expression that reaches itself (a local whose stores read it) is its type while it
    // is being read.
    try memo.map.put(c.allocator, key, typed);
    var out = (try operation(c, file, node, pointer, depth)).meet(typed);
    if (out.empty()) out = typed;
    out = try refined(c, file, node, out, pointer, depth);
    try memo.map.put(c.allocator, key, out);
    return out;
}

/// `out` narrowed by the comparisons holding at `node`: what they put it at least and at most,
/// read through one comparison, or two that relate it to a value (`a <= b`, `b <= c`).
fn refined(c: *Context, file: Project.FileId, node: Ast.Node.Index, out: Interval, pointer: u16, depth: u8) Context.Error!Interval {
    const tree = &c.project.files[file.raw()].tree;
    const tag = tree.nodeTag(node);
    switch (tag) {
        .identifier, .field_access, .add, .sub, .assign_add, .assign_sub => {},
        else => return out,
    }
    if (out.least == out.most) return out;
    var value: Linear = .{};
    if (!value.put(tree, node, false)) return out;
    var r = out;
    // A position the function indexes or slices memory with is below a length.
    if ((tag == .identifier or tag == .field_access) and try position(c, file, node)) r.most = @min(r.most, length(pointer));
    r.least = @max(r.least, try least(c, file, value, node, pointer, depth, false));
    r.most = @min(r.most, -(try least(c, file, value.negated(), node, pointer, depth, false)));
    return if (r.empty()) out else r;
}

/// Whether `node` is arithmetic on a pointer (`ptr + i`): an address, which no checked
/// overflow stops.
pub fn addresses(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const lhs = tree.nodeData(node).node_and_node[0];
    return switch (try c.facts.resolve(file, bare(tree, lhs))) {
        .pointer => true,
        else => false,
    };
}

/// What an expression's own operation gives, before its type and the comparisons narrow it.
fn operation(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!Interval {
    const tree = &c.project.files[file.raw()].tree;
    const next = depth + 1;
    switch (tree.nodeTag(node)) {
        .number_literal => return if (literal(tree, node)) |value| .exactly(value) else .any,
        .char_literal => return .{ .least = 0, .most = 0x10ffff },
        .identifier => {
            const ref = c.project.models[file.raw()].reference(node) orelse return .any;
            return declared(c, .{ .file = file, .index = ref.declaration orelse return .any }, pointer);
        },
        .field_access => {
            const name = tree.tokenSlice(tree.nodeData(node).node_and_token[1]);
            // A length of memory the program holds: below half the address space.
            if (std.mem.eql(u8, name, "len")) return .{ .least = 0, .most = length(pointer) };
            const decl = (try c.facts.definition(file, node)) orelse return .any;
            if (c.project.models[decl.file.raw()].declarations[decl.index].kind == .field) return stored(c, decl, pointer);
            return declared(c, decl, pointer);
        },
        .grouped_expression, .unwrap_optional => return bound(c, file, tree.nodeData(node).node_and_token[0], pointer, next),
        .@"try" => return bound(c, file, tree.nodeData(node).node, pointer, next),
        .negation => return (try bound(c, file, tree.nodeData(node).node, pointer, next)).negated(),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return either(c, file, &.{ lhs, rhs }, pointer, next);
        },
        .add, .assign_add, .assign_add_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try bound(c, file, lhs, pointer, next)).plus(try bound(c, file, rhs, pointer, next));
        },
        .sub, .assign_sub => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            // What is left of a value once its quotient by `k` is taken away (`y - @divFloor(y,
            // k) * k`) is a remainder, below `k`, and never below zero for a floored quotient.
            if (try remainder(c, file, lhs, rhs)) |left| {
                const most = (try bound(c, file, left.divisor, pointer, next)).magnitude() -| 1;
                return .{ .least = if (left.floored) 0 else -@as(i132, most), .most = most };
            }
            return (try bound(c, file, lhs, pointer, next)).minus(try bound(c, file, rhs, pointer, next));
        },
        .mul, .assign_mul, .assign_mul_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return (try bound(c, file, lhs, pointer, next)).times(try bound(c, file, rhs, pointer, next));
        },
        .div => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return quotient(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next), false);
        },
        .mod => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return rest(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next), false);
        },
        .shl, .assign_shl, .assign_shl_sat => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const by = literal(tree, rhs) orelse return .any;
            if (by >= 128) return .any;
            const out = (try bound(c, file, lhs, pointer, next)).times(.exactly(@as(i132, 1) << @intCast(by)));
            // `<<` drops the bits it shifts out: a product past the type is not the value.
            if (tree.nodeTag(node) == .shl and !out.within((try typeOf(c, file, node, pointer, next)).values())) return .any;
            return out;
        },
        .shr => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try bound(c, file, lhs, pointer, next);
            const by = literal(tree, rhs) orelse return if (left.least >= 0) .{ .least = 0, .most = left.most } else .{ .least = @min(left.least, 0), .most = @max(left.most, 0) };
            const shift: u8 = @intCast(@min(by, 131));
            return .{ .least = left.least >> shift, .most = left.most >> shift };
        },
        .bit_and => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try bound(c, file, lhs, pointer, next);
            const right = try bound(c, file, rhs, pointer, next);
            // A mask by a value never below zero keeps the result between zero and it.
            if (left.least >= 0 and right.least >= 0) return .{ .least = 0, .most = @min(left.most, right.most) };
            if (left.least >= 0) return .{ .least = 0, .most = left.most };
            if (right.least >= 0) return .{ .least = 0, .most = right.most };
            return .any;
        },
        .bit_or, .bit_xor, .assign_bit_or, .assign_bit_xor => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try bound(c, file, lhs, pointer, next);
            const right = try bound(c, file, rhs, pointer, next);
            if (left.least < 0 or right.least < 0) return .any;
            const most: u128 = @intCast(@min(@max(left.most, right.most), std.math.maxInt(u128)));
            return .{ .least = 0, .most = filled(128 - @clz(most)) };
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(node).?;
            const otherwise = branch.ast.else_expr.unwrap() orelse return bound(c, file, branch.ast.then_expr, pointer, next);
            return either(c, file, &.{ branch.ast.then_expr, otherwise }, pointer, next);
        },
        .@"switch", .switch_comma => {
            var targets: std.ArrayList(Ast.Node.Index) = .empty;
            for (tree.fullSwitch(node).?.ast.cases) |case| {
                const full = tree.fullSwitchCase(case) orelse return .any;
                try targets.append(c.allocator, full.ast.target_expr);
            }
            return either(c, file, targets.items, pointer, next);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return builtin(c, file, node, pointer, next),
        else => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node) orelse return .any;
            return switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |decl| returned(c, decl, pointer),
                else => .any,
            };
        },
    }
}

/// What one of several operands gives (the branches of an `if` or a `switch`, the sides of an
/// `orelse`): the widest of those that give a value, not those that leave.
fn either(c: *Context, file: Project.FileId, operands: []const Ast.Node.Index, pointer: u16, depth: u8) Context.Error!Interval {
    const tree = &c.project.files[file.raw()].tree;
    var out: ?Interval = null;
    for (operands) |each| {
        if (leaves(tree, each)) continue;
        const value = try bound(c, file, each, pointer, depth);
        out = if (out) |o| o.join(value) else value;
    }
    return out orelse .any;
}

/// What a function returns, read once per function and pointer width: the widest of its
/// `return`s, each read in its body.
const Returns = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty };

fn returned(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const memo = try c.facts.memo(Returns);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A function that reaches itself is read as unbounded while it is being read.
    try memo.map.put(c.allocator, key, .any);
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const function = model.declarations[decl.index].node;
    if (tree.nodeTag(function) != .fn_decl) return .any;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var out: ?Interval = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last or enclosing(tree, model, node) != function) continue;
        const value = try bound(c, decl.file, tree.nodeData(node).opt_node.unwrap() orelse continue, pointer, 0);
        out = if (out) |o| o.join(value) else value;
    }
    const result = out orelse Interval.any;
    try memo.map.put(c.allocator, key, result);
    return result;
}

/// The function a node is in.
fn enclosing(tree: *const Ast, model: anytype, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// What a declaration a name resolves to gives: a constant its initializer, a local variable
/// what is stored into it, a `for` capture its range's positions; a parameter or another
/// capture only its type.
fn declared(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const record = c.project.models[decl.file.raw()].declarations[decl.index];
    return switch (record.kind) {
        .variable => {
            const tree = &c.project.files[decl.file.raw()].tree;
            const variable = tree.fullVarDecl(record.node) orelse return .any;
            if (tree.tokenTag(variable.ast.mut_token) == .keyword_const) return constant(c, decl, pointer);
            return assigned(c, decl, pointer);
        },
        .capture => captured(c, decl, pointer),
        else => .any,
    };
}

/// Every store into a field, found once over the program: by the field it resolves to, or,
/// where its target does not resolve, by the field's name, which every field of that name
/// then takes. A field holds at most the widest of its stores, each read where it is made.
const Stores = struct {
    scanned: bool = false,
    by_field: std.AutoHashMapUnmanaged(Facts.Decl, std.ArrayList(Store)) = .empty,
    by_name: std.StringHashMapUnmanaged(std.ArrayList(Store)) = .empty,
    /// Types whose values the program views as bytes (`std.mem.asBytes`, `bytesAsValue`): their
    /// fields hold whatever the bytes do.
    viewed: std.AutoHashMapUnmanaged(struct { u32, u32 }, void) = .empty,
    /// A view or a computed `@field` store whose type does not resolve: no field is read by its
    /// stores.
    blind: bool = false,
    ranges: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty,
};
/// A store: the value it gives, read in its file, or none where its range is not read (a
/// field given by address, a destructure, wrapping arithmetic).
const Store = struct { file: Project.FileId, value: ?Ast.Node.Index };

/// What a field holds at most: the widest of its default and its stores, or null where a
/// store is not read or a value of its type is made otherwise (bytes viewed as it, a layout
/// that bytes define). A field whose stores read it again is unbounded while it is read, so
/// its type bounds it there.
fn stored(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const stores = try c.facts.memo(Stores);
    if (!stores.scanned) {
        stores.scanned = true;
        try scan(c, stores);
    }
    if (stores.blind) return .any;
    const input = c.project.inputs[decl.file.raw()];
    if (!input.selected or input.classification == .@"test") return .any;
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    // A layout bytes define (`extern`, `packed`) is any bytes a read or a cast gives it.
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, model.scopes[record.scope].node) orelse return .any;
    if (container.layout_token != null) return .any;
    if (stores.viewed.contains(.{ decl.file.raw(), record.scope })) return .any;
    const key = .{ decl, pointer };
    if (stores.ranges.get(key)) |known| return known;
    try stores.ranges.put(c.allocator, key, .any);
    const full = tree.fullContainerField(record.node) orelse return .any;
    var out: ?Interval = null;
    if (full.ast.value_expr.unwrap()) |default| out = try bound(c, decl.file, default, pointer, 0);
    const lists = [_]?std.ArrayList(Store){ stores.by_field.get(decl), stores.by_name.get(record.name) };
    const result: Interval = read: {
        for (lists) |list| for (if (list) |l| l.items else &.{}) |store| {
            const value = try bound(c, store.file, store.value orelse break :read .any, pointer, 0);
            out = if (out) |o| o.join(value) else value;
        };
        break :read out orelse .any;
    };
    try stores.ranges.put(c.allocator, key, result);
    return result;
}

/// Finds every store into a field in the program's own code, its tests aside.
fn scan(c: *Context, stores: *Stores) Context.Error!void {
    for (c.project.inputs, 0..) |input, f| {
        if (!input.selected or input.classification == .@"test") continue;
        const file = Project.FileId.fromRaw(@intCast(f));
        const tree = &c.project.files[f].tree;
        const model = &c.project.models[f];
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            switch (tag) {
                .assign => {
                    const target, const value = tree.nodeData(node).node_and_node;
                    try storeInto(c, stores, file, target, value);
                },
                .assign_add, .assign_add_sat, .assign_mul, .assign_mul_sat, .assign_shl, .assign_shl_sat, .assign_bit_or, .assign_bit_xor => try storeInto(c, stores, file, tree.nodeData(node).node_and_node[0], node),
                .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap => try storeInto(c, stores, file, tree.nodeData(node).node_and_node[0], null),
                // A difference, quotient, shift right or remainder never takes an unsigned
                // value past what it was; a signed one may cross to a larger magnitude.
                .assign_sub, .assign_sub_sat, .assign_div, .assign_shr, .assign_mod, .assign_bit_and => {
                    const target = tree.nodeData(node).node_and_node[0];
                    if (!try unsignedAt(c, file, target)) try storeInto(c, stores, file, target, null);
                },
                .assign_destructure => for (tree.assignDestructure(node).ast.variables) |variable| try storeInto(c, stores, file, variable, null),
                // A field given by address is written by whoever takes it.
                .address_of => try storeInto(c, stores, file, bare(tree, tree.nodeData(node).node), null),
                .call_one, .call_one_comma, .call, .call_comma => try viewed(c, stores, file, node),
                else => {
                    var literal_buffer: [2]Ast.Node.Index = undefined;
                    const literal_node = tree.fullStructInit(&literal_buffer, node) orelse continue;
                    if (inTest(tree, model, node)) continue;
                    var holder = try c.facts.literalType(file, node);
                    while (true) holder = switch (holder) {
                        .optional, .error_union, .pointer => |inner| inner.*,
                        else => break,
                    };
                    for (literal_node.ast.fields) |value| {
                        if (tree.firstToken(value) < 2) continue;
                        const name = tree.tokenSlice(tree.firstToken(value) - 2);
                        const store: Store = .{ .file = file, .value = value };
                        switch (holder) {
                            .container, .instance => |k| if (c.facts.member(k, name)) |decl| {
                                try add(c, stores, decl, null, store);
                                continue;
                            },
                            else => {},
                        }
                        try add(c, stores, null, name, store);
                    }
                },
            }
        }
    }
}

/// Records a store of `value` into `target`, where the target is a field.
fn storeInto(c: *Context, stores: *Stores, file: Project.FileId, target: Ast.Node.Index, value: ?Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    if (inTest(tree, &c.project.models[file.raw()], target)) return;
    const store: Store = .{ .file = file, .value = value };
    switch (tree.nodeTag(target)) {
        .field_access => {
            if (try c.facts.definition(file, target)) |decl| if (c.project.models[decl.file.raw()].declarations[decl.index].kind == .field) return add(c, stores, decl, null, store);
            return add(c, stores, null, tree.tokenSlice(tree.nodeData(target).node_and_token[1]), store);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "@field")) return;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, target, &buffer);
            if (args.len == 2 and tree.nodeTag(args[1]) == .string_literal) {
                const spelled = tree.tokenSlice(tree.nodeMainToken(args[1]));
                return add(c, stores, null, spelled[1 .. spelled.len - 1], store);
            }
            // A name the program computes (an `inline for` over a type's fields) may be any of
            // its type's fields, which its type then bounds. Where the type does not resolve
            // (a generic decoder's), only input stored by it reaches past what the stores say.
            switch (try typeOfValue(c, file, args[0])) {
                .container, .instance => |k| try stores.viewed.put(c.allocator, .{ k.file.raw(), k.scope }, {}),
                else => if (try holdsInput(c, file, value)) {
                    stores.blind = true;
                },
            }
        },
        else => {},
    }
}

fn add(c: *Context, stores: *Stores, decl: ?Facts.Decl, name: ?[]const u8, store: Store) Context.Error!void {
    const list = if (decl) |d| blk: {
        const entry = try stores.by_field.getOrPut(c.allocator, d);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        break :blk entry.value_ptr;
    } else blk: {
        const entry = try stores.by_name.getOrPut(c.allocator, name.?);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        break :blk entry.value_ptr;
    };
    try list.append(c.allocator, store);
}

/// Marks the type whose values a call makes from input's bytes: `bytesAsValue`,
/// `bytesAsSlice` and `bytesToValue` over input, and `std.mem.asBytes(&x)` or
/// `sliceAsBytes(xs)` given to a read or as `@memcpy`'s destination for input. A view of the
/// program's own bytes (a wipe, a table laid over its buffer) holds no value a peer chose.
fn viewed(c: *Context, stores: *Stores, file: Project.FileId, node: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return;
    const callee = tree.lastToken(call.ast.fn_expr);
    if (tree.tokenTag(callee) != .identifier) return;
    const name = tree.tokenSlice(callee);
    const named_type = for ([_][]const u8{ "bytesAsValue", "bytesAsSlice", "bytesToValue" }) |each| {
        if (std.mem.eql(u8, name, each)) break true;
    } else false;
    const of_value = std.mem.eql(u8, name, "asBytes") or std.mem.eql(u8, name, "sliceAsBytes");
    if (!named_type and !of_value) return;
    if (call.ast.params.len == 0) return;
    if (named_type and (call.ast.params.len < 2 or !try holdsInput(c, file, call.ast.params[1]))) return;
    if (of_value and !try takesInput(c, file, node)) return;
    switch (try typeOfValue(c, file, call.ast.params[0])) {
        .container, .instance => |k| try stores.viewed.put(c.allocator, .{ k.file.raw(), k.scope }, {}),
        .primitive, .scalar => {},
        else => stores.blind = true,
    }
}

/// What a value or a type names, seen through pointers, optionals, arrays and error unions.
fn typeOfValue(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Facts.Value {
    var value = try c.facts.resolve(file, node);
    while (true) value = switch (value) {
        .optional, .error_union, .pointer, .array => |inner| inner.*,
        else => return value,
    };
}

/// Whether a value may hold input: what the input fact gives it, or a store whose value is
/// not read.
fn holdsInput(c: *Context, file: Project.FileId, value: ?Ast.Node.Index) Context.Error!bool {
    const node = value orelse return true;
    const flow = try Taint.get(c, .input);
    return try Taint.levelAt(c, flow, file, node) != .clean;
}

/// Whether bytes a view gives are filled with input where it is made: given to a read, or as
/// `@memcpy`'s destination for input.
fn takesInput(c: *Context, file: Project.FileId, view: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const parent = c.project.models[file.raw()].node_parents[@backingInt(view)] orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, parent)) |call| return Taint.isRead(c, try Taint.get(c, .input), file, call);
    if (tree.nodeTag(parent) != .builtin_call_two and tree.nodeTag(parent) != .builtin_call_two_comma) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@memcpy")) return false;
    var args_buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, parent, &args_buffer);
    return args.len == 2 and args[0] == view and try holdsInput(c, file, args[1]);
}

/// Whether `node` is inside a `test` block.
fn inTest(tree: *const Ast, model: anytype, node: Ast.Node.Index) bool {
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .test_decl) return true;
    }
    return false;
}

/// What a builtin's operation gives.
fn builtin(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!Interval {
    const tree = &c.project.files[file.raw()].tree;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    const is = struct {
        fn one(n: []const u8, comptime names: []const []const u8) bool {
            inline for (names) |each| if (std.mem.eql(u8, n, each)) return true;
            return false;
        }
    }.one;
    if (is(name, &.{"@intFromBool"})) return .{ .least = 0, .most = 1 };
    // A count of bits in a type of at most 65535 bits.
    if (is(name, &.{ "@ctz", "@clz", "@popCount" })) return .{ .least = 0, .most = std.math.maxInt(u16) };
    if (is(name, &.{ "@sizeOf", "@alignOf", "@bitSizeOf", "@offsetOf", "@bitOffsetOf" })) return .{ .least = 0, .most = length(pointer) };
    if (args.len == 0) return .any;
    // A conversion keeps its operand's value: `@as` by the type it names, `@intCast` where it
    // does not fail. `@truncate` keeps it only where the destination holds it.
    if (is(name, &.{ "@as", "@intCast" })) return bound(c, file, args[args.len - 1], pointer, depth);
    if (is(name, &.{"@truncate"})) {
        const value = try bound(c, file, args[0], pointer, depth);
        const into = (try destination(c, file, node, pointer)) orelse return .any;
        return if (value.within(into.values())) value else .any;
    }
    if (is(name, &.{"@abs"})) {
        const value = try bound(c, file, args[0], pointer, depth);
        if (value.least >= 0) return value;
        if (value.most <= 0) return value.negated();
        return .{ .least = 0, .most = @max(-value.least, value.most) };
    }
    if (args.len != 2) return .any;
    const left = try bound(c, file, args[0], pointer, depth);
    const right = try bound(c, file, args[1], pointer, depth);
    if (is(name, &.{"@min"})) return .{ .least = @min(left.least, right.least), .most = @min(left.most, right.most) };
    if (is(name, &.{"@max"})) return .{ .least = @max(left.least, right.least), .most = @max(left.most, right.most) };
    if (is(name, &.{ "@divFloor", "@divExact" })) return quotient(left, right, true);
    if (is(name, &.{"@divTrunc"})) return quotient(left, right, false);
    if (is(name, &.{"@mod"})) return rest(left, right, true);
    if (is(name, &.{"@rem"})) return rest(left, right, false);
    if (is(name, &.{"@shlExact"})) {
        const by = literal(tree, args[1]) orelse return .any;
        if (by >= 128) return .any;
        return left.times(.exactly(@as(i132, 1) << @intCast(by)));
    }
    if (is(name, &.{"@shrExact"})) {
        const by = literal(tree, args[1]) orelse return .any;
        const shift: u8 = @intCast(@min(by, 131));
        return .{ .least = left.least >> shift, .most = left.most >> shift };
    }
    return .any;
}

/// What a constant's initializer gives (its type narrows it where it spells one).
fn constant(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const tree = &c.project.files[decl.file.raw()].tree;
    const variable = tree.fullVarDecl(c.project.models[decl.file.raw()].declarations[decl.index].node) orelse return .any;
    const init = variable.ast.init_node.unwrap() orelse return .any;
    const memo = try c.facts.memo(Constants);
    const key = .{ decl, pointer };
    if (memo.bounds.get(key)) |known| return known;
    // A constant that reaches itself is read as unbounded while it is being read.
    try memo.bounds.put(c.allocator, key, .any);
    const out = try bound(c, decl.file, init, pointer, 0);
    try memo.bounds.put(c.allocator, key, out);
    return out;
}

/// Constants' ranges and types, each read once per pointer width from its initializer, so a
/// chain of constants is read as far as it goes and the depth limit bounds one expression's
/// nesting alone; and local variables' ranges, each read once from its stores.
const Constants = struct {
    bounds: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty,
    types: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Typed) = .empty,
    locals: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty,
};

/// What a local variable holds: the widest of its initializer and its function's stores into
/// it, each read where it is made (so a position advanced under `pos + n <= buf.len` holds
/// at most the length). A store that reads the variable without a comparison bounding it
/// grows it to its type, as does a store the reading does not follow: wrapping arithmetic, a
/// destructure, or its address given away. A container-level variable is its type.
fn assigned(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const record = model.declarations[decl.index];
    const function = enclosing(tree, model, record.node) orelse return .any;
    const variable = tree.fullVarDecl(record.node) orelse return .any;
    const memo = try c.facts.memo(Constants);
    const key = .{ decl, pointer };
    if (memo.locals.get(key)) |known| return known;
    try memo.locals.put(c.allocator, key, .any);
    var out: ?Interval = null;
    if (variable.ast.init_node.unwrap()) |init| {
        if (!(tree.nodeTag(init) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "undefined"))) out = try bound(c, decl.file, init, pointer, 0);
    }
    const decreases_to_zero = if (variable.ast.type_node.unwrap()) |t|
        if (try named(c, decl.file, t, pointer)) |int| !int.signed else false
    else if (variable.ast.init_node.unwrap()) |init| try unsignedAt(c, decl.file, init) else false;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    const result: Interval = scan: for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const value: Interval = switch (tag) {
            .assign => blk: {
                const target, const given = tree.nodeData(node).node_and_node;
                if (!refersTo(model, tree, target, decl.index)) continue;
                break :blk try bound(c, decl.file, given, pointer, 0);
            },
            .assign_add, .assign_add_sat, .assign_mul, .assign_mul_sat, .assign_shl, .assign_shl_sat, .assign_bit_or, .assign_bit_xor => blk: {
                if (!refersTo(model, tree, tree.nodeData(node).node_and_node[0], decl.index)) continue;
                break :blk try bound(c, decl.file, node, pointer, 0);
            },
            // A difference, quotient, shift right, remainder or mask never takes an unsigned
            // value past what it was, only down to zero; a signed one may cross to a larger
            // magnitude.
            .assign_sub, .assign_sub_sat, .assign_div, .assign_shr, .assign_mod, .assign_bit_and => blk: {
                if (!refersTo(model, tree, tree.nodeData(node).node_and_node[0], decl.index)) continue;
                if (!decreases_to_zero) break :scan .any;
                break :blk .exactly(0);
            },
            .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap => {
                if (refersTo(model, tree, tree.nodeData(node).node_and_node[0], decl.index)) break :scan .any;
                continue;
            },
            .assign_destructure => {
                for (tree.assignDestructure(node).ast.variables) |each| if (refersTo(model, tree, each, decl.index)) break :scan .any;
                continue;
            },
            .address_of => {
                if (refersTo(model, tree, bare(tree, tree.nodeData(node).node), decl.index)) break :scan .any;
                continue;
            },
            else => continue,
        };
        out = if (out) |o| o.join(value) else value;
    } else out orelse .any;
    try memo.locals.put(c.allocator, key, result);
    return result;
}

/// Whether `node` is a name that resolves to declaration `index` of its file.
fn refersTo(model: anytype, tree: *const Ast, node: Ast.Node.Index, index: u32) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const ref = model.reference(node) orelse return false;
    return ref.declaration == index;
}

/// What a `for` capture of a range holds: a position from its start up to below its end, or
/// below a length where the range has none (`for (items, 0..) |item, i|`).
fn captured(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = c.project.models[decl.file.raw()].declarations[decl.index];
    const loop = tree.fullFor(record.node) orelse return .any;
    var position_of: usize = 0;
    var token = loop.payload_token;
    while (token < record.token) : (token += 1) {
        if (tree.tokenTag(token) == .identifier) position_of += 1;
    }
    if (position_of >= loop.ast.inputs.len) return .any;
    const input = loop.ast.inputs[position_of];
    if (tree.nodeTag(input) != .for_range) return .any;
    const start, const end = tree.nodeData(input).node_and_opt_node;
    const most = if (end.unwrap()) |e| (try bound(c, decl.file, e, pointer, 0)).most - 1 else length(pointer) - 1;
    return .{ .least = (try bound(c, decl.file, start, pointer, 0)).least, .most = most };
}

/// The type of a constant that spells none: its initializer's.
fn constantType(c: *Context, decl: Facts.Decl, init: Ast.Node.Index, pointer: u16) Context.Error!Typed {
    const memo = try c.facts.memo(Constants);
    const key = .{ decl, pointer };
    if (memo.types.get(key)) |known| return known;
    try memo.types.put(c.allocator, key, .unknown);
    const out = try typeOf(c, decl.file, init, pointer, 0);
    try memo.types.put(c.allocator, key, out);
    return out;
}

/// The integer type `node` computes in.
fn typeOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!Typed {
    if (depth > depth_limit) return .unknown;
    const tree = &c.project.files[file.raw()].tree;
    const next = depth + 1;
    switch (tree.nodeTag(node)) {
        .number_literal, .char_literal => return .literal,
        .grouped_expression, .unwrap_optional => return typeOf(c, file, tree.nodeData(node).node_and_token[0], pointer, next),
        .@"try", .negation, .bit_not => return typeOf(c, file, tree.nodeData(node).node, pointer, next),
        .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat, .mul, .mul_wrap, .mul_sat, .div, .mod, .bit_and, .bit_or, .bit_xor, .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return Typed.peer(try typeOf(c, file, lhs, pointer, next), try typeOf(c, file, rhs, pointer, next));
        },
        .shl, .shl_sat, .shr => return typeOf(c, file, tree.nodeData(node).node_and_node[0], pointer, next),
        .@"if", .if_simple => {
            const branch = tree.fullIf(node).?;
            const then = try typeOf(c, file, branch.ast.then_expr, pointer, next);
            const otherwise = branch.ast.else_expr.unwrap() orelse return then;
            return Typed.peer(then, try typeOf(c, file, otherwise, pointer, next));
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            for ([_][]const u8{ "@intCast", "@truncate", "@bitCast" }) |cast| if (std.mem.eql(u8, name, cast)) {
                return if (try destination(c, file, node, pointer)) |int| .{ .int = int } else .unknown;
            };
            for ([_][]const u8{ "@ctz", "@clz", "@popCount", "@intFromBool" }) |count| if (std.mem.eql(u8, name, count)) return .literal;
            for ([_][]const u8{ "@min", "@max", "@divFloor", "@divTrunc", "@divExact", "@mod", "@rem" }) |peer| if (std.mem.eql(u8, name, peer) and args.len == 2) {
                return Typed.peer(try typeOf(c, file, args[0], pointer, next), try typeOf(c, file, args[1], pointer, next));
            };
        },
        .identifier, .field_access => {
            if (tree.nodeTag(node) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), "len")) return .{ .int = .{ .bits = pointer, .signed = false } };
            const decl = (try c.facts.definition(file, node)) orelse if (tree.nodeTag(node) == .identifier) blk: {
                const ref = c.project.models[file.raw()].reference(node) orelse break :blk null;
                break :blk if (ref.declaration) |d| Facts.Decl{ .file = file, .index = d } else null;
            } else null;
            // A constant with no type of its own has its initializer's: a number literal's
            // comptime type, which takes the other operand's.
            if (decl) |d| if (try untyped(c, d)) |init| return constantType(c, d, init, pointer);
        },
        else => {},
    }
    return integer(try c.facts.resolve(file, node), pointer);
}

/// A constant's initializer, where it spells no type.
fn untyped(c: *Context, decl: Facts.Decl) Context.Error!?Ast.Node.Index {
    const record = c.project.models[decl.file.raw()].declarations[decl.index];
    if (record.kind != .variable) return null;
    const tree = &c.project.files[decl.file.raw()].tree;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const or variable.ast.type_node.unwrap() != null) return null;
    return variable.ast.init_node.unwrap();
}

/// The integer type a resolved value is, seen through an optional or an error union.
fn integer(value: Facts.Value, pointer: u16) Typed {
    switch (value) {
        .optional, .error_union => |inner| return integer(inner.*, pointer),
        .primitive => |name| {
            if (std.mem.eql(u8, name, "comptime_int")) return .literal;
            if (std.mem.eql(u8, name, "usize")) return .{ .int = .{ .bits = pointer, .signed = false } };
            if (std.mem.eql(u8, name, "isize")) return .{ .int = .{ .bits = pointer, .signed = true } };
            if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return .unknown;
            const bits = std.fmt.parseUnsigned(u16, name[1..], 10) catch return .unknown;
            return .{ .int = .{ .bits = bits, .signed = name[0] == 'i' } };
        },
        else => return .unknown,
    }
}

/// The type a conversion's result is read into: what `@as` names, a typed constant or
/// variable it initializes, what it is assigned to, or the function's result it returns.
fn destination(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try" => continue,
            .builtin_call_two, .builtin_call_two_comma => {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@as")) return null;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, parent, &buffer);
                if (args.len != 2 or args[1] != at) return null;
                return named(c, file, args[0], pointer);
            },
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                return switch (try typeOf(c, file, lhs, pointer, 0)) {
                    .int => |int| int,
                    else => null,
                };
            },
            .@"return" => {
                var scope = parent;
                while (model.node_parents[@backingInt(scope)]) |up| : (scope = up) {
                    if (tree.nodeTag(up) != .fn_decl) continue;
                    var buffer: [1]Ast.Node.Index = undefined;
                    const proto = tree.fullFnProto(&buffer, tree.nodeData(up).node_and_node[0]) orelse return null;
                    return named(c, file, proto.ast.return_type.unwrap() orelse return null, pointer);
                }
                return null;
            },
            else => {
                if (tree.fullVarDecl(parent)) |variable| {
                    if (variable.ast.init_node.unwrap() != at) return null;
                    return named(c, file, variable.ast.type_node.unwrap() orelse return null, pointer);
                }
                var call_buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&call_buffer, parent)) |call| return argument(c, file, call, at, pointer);
                var init_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&init_buffer, parent)) |_| return field(c, file, parent, at, pointer);
                return null;
            },
        }
    }
    return null;
}

/// The integer type of the parameter `arg` is given to, where the call resolves.
fn argument(c: *Context, file: Project.FileId, call: Ast.full.Call, arg: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    const tree = &c.project.files[file.raw()].tree;
    const position_of = std.mem.findScalar(Ast.Node.Index, call.ast.params, arg) orelse return null;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        else => return null,
    };
    // A method called on a value takes it as its first parameter.
    var skip: usize = 0;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        var receiver = try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        if (receiver == .pointer) receiver = receiver.pointer.*;
        if (receiver == .instance) skip = 1;
    }
    const callee_tree = &c.project.files[decl.file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = callee_tree.fullFnProto(&buffer, c.project.models[decl.file.raw()].declarations[decl.index].node) orelse return null;
    var it = proto.iterate(callee_tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        if (index != position_of + skip) continue;
        return named(c, decl.file, param.type_expr orelse return null, pointer);
    }
    return null;
}

/// The integer type of the field a struct literal's `value` initializes.
fn field(c: *Context, file: Project.FileId, literal_node: Ast.Node.Index, value: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    const tree = &c.project.files[file.raw()].tree;
    var holder = try c.facts.literalType(file, literal_node);
    while (true) holder = switch (holder) {
        .optional, .error_union, .pointer => |inner| inner.*,
        else => break,
    };
    const container = switch (holder) {
        .container, .instance => |k| k,
        else => return null,
    };
    if (tree.firstToken(value) < 2) return null;
    const name = tree.tokenSlice(tree.firstToken(value) - 2);
    const decl = c.facts.member(container, name) orelse return null;
    if (c.project.models[decl.file.raw()].declarations[decl.index].kind != .field) return null;
    return switch (integer(try c.facts.declaration(decl), pointer)) {
        .int => |int| int,
        else => null,
    };
}

/// The integer type a type expression names.
fn named(c: *Context, file: Project.FileId, type_node: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    return switch (integer(try c.facts.resolve(file, type_node), pointer)) {
        .int => |int| int,
        else => null,
    };
}

/// An integer literal's value.
fn literal(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    if (tree.nodeTag(node) != .number_literal) return null;
    return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
        .int => |value| value,
        else => null,
    };
}

/// The greatest value of `bits` bits.
fn filled(bits: u16) u128 {
    return if (bits >= 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(bits)) - 1;
}

/// The greatest length of memory at a pointer width: below half the address space.
fn length(pointer: u16) u128 {
    return filled(pointer - 1);
}

/// A quotient's range. A divisor that is never zero gives the quotient of the corners (each
/// side of zero apart); one that may be zero stops the program there, and otherwise keeps the
/// quotient's magnitude at most the dividend's.
fn quotient(dividend: Interval, divisor: Interval, floored: bool) Interval {
    if (divisor.least >= 1 or divisor.most <= -1) {
        var out: ?Interval = null;
        for ([_]i132{ dividend.least, dividend.most }) |x| for ([_]i132{ divisor.least, divisor.most }) |y| {
            const q: Interval = .exactly(if (floored) @divFloor(x, y) else @divTrunc(x, y));
            out = if (out) |o| o.join(q) else q;
        };
        return out.?;
    }
    const most: i132 = @intCast(@min(dividend.magnitude(), Interval.far));
    return if (dividend.least >= 0 and divisor.least >= 0) .{ .least = 0, .most = dividend.most } else .{ .least = -most, .most = most };
}

/// A remainder's range: below the divisor's magnitude, on the dividend's side of zero (`%`,
/// `@rem`) or the divisor's (`@mod`), and never past a dividend that is not below zero.
fn rest(dividend: Interval, divisor: Interval, modulo: bool) Interval {
    const below: i132 = @intCast(@min(divisor.magnitude() -| 1, Interval.far));
    if (modulo) {
        if (divisor.least >= 1) return .{ .least = 0, .most = if (dividend.least >= 0) @min(dividend.most, below) else below };
        if (divisor.most <= -1) return .{ .least = -below, .most = 0 };
        return .{ .least = -below, .most = below };
    }
    return .{
        .least = if (dividend.least >= 0) 0 else @max(dividend.least, -below),
        .most = if (dividend.most <= 0) 0 else @min(dividend.most, below),
    };
}

/// A comparison that holds where a value is read: `small` below `large`, or at most it.
const Fact = struct { small: Ast.Node.Index, large: Ast.Node.Index, strict: bool };

/// The comparisons holding at each node, gathered once.
const Held = struct { map: std.AutoHashMapUnmanaged(struct { u32, u32 }, []const Fact) = .empty };

/// The comparisons that hold where `node` is evaluated: the conditions of the branches and
/// loops it is in and of the `and` and `or` it is the right side of, the negated conditions of
/// the earlier statements of its blocks that leave when they hold (`if (end > buf.len) return
/// error.Short;`), and the conditions of the contracts among those statements (std's `assert`,
/// aegis's `assert.invariant`, `pre` and `post`), which hold past them in a build that checks
/// them. A comparison holds while nothing between it and `node` assigns what it compares.
fn facts(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Fact {
    const memo = try c.facts.memo(Held);
    const key = .{ file.raw(), @backingInt(node) };
    if (memo.map.get(key)) |known| return known;
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var out: std.ArrayList(Fact) = .empty;
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .fn_decl => break,
            .bool_and, .bool_or => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs == at) try held(c, file, &out, lhs, tree.nodeTag(parent) == .bool_and, node);
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.blockStatements(&buffer, parent).?) |statement| {
                    if (statement == at) break;
                    if (try contract(c, file, statement)) |condition| {
                        try held(c, file, &out, condition, true, node);
                        continue;
                    }
                    const branch = tree.fullIf(statement) orelse continue;
                    if (branch.ast.else_expr != .none or !leaves(tree, branch.ast.then_expr)) continue;
                    try held(c, file, &out, branch.ast.cond_expr, false, node);
                }
            },
            else => {
                if (tree.fullIf(parent)) |branch| {
                    if (branch.ast.then_expr == at) try held(c, file, &out, branch.ast.cond_expr, true, node);
                    if (branch.ast.else_expr.unwrap() == at) try held(c, file, &out, branch.ast.cond_expr, false, node);
                } else if (tree.fullWhile(parent)) |loop| {
                    if (loop.ast.then_expr == at or loop.ast.cont_expr.unwrap() == at) try held(c, file, &out, loop.ast.cond_expr, true, node);
                }
            },
        }
    }
    const found = try out.toOwnedSlice(c.allocator);
    try memo.map.put(c.allocator, key, found);
    return found;
}

/// std's `assert`, found once.
const Contracts = struct { found: bool = false, asserts: []const Facts.Decl = &.{} };

/// The condition a statement checks as a contract that stops the program where it fails: a
/// call to std's `assert` (or a private alias of it) or to aegis's `assert.invariant`, `pre` or
/// `post`. aegis's `debug` checks only in Debug builds, so it holds nothing after it.
fn contract(c: *Context, file: Project.FileId, statement: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, statement) orelse return null;
    if (call.ast.params.len == 0) return null;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        else => return null,
    };
    const memo = try c.facts.memo(Contracts);
    if (!memo.found) {
        memo.found = true;
        var asserts: std.ArrayList(Facts.Decl) = .empty;
        for ((try Governed.declarations(c, "std", "debug.assert")) orelse &.{}) |each| try asserts.append(c.allocator, (try c.facts.origin(each)) orelse each);
        memo.asserts = try asserts.toOwnedSlice(c.allocator);
    }
    const origin = (try c.facts.origin(decl)) orelse decl;
    for (memo.asserts) |each| if (each.file.eql(origin.file) and each.index == origin.index) return call.ast.params[0];
    const record = c.project.models[origin.file.raw()].declarations[origin.index];
    for ([_][]const u8{ "invariant", "pre", "post" }) |name| if (std.mem.eql(u8, record.name, name)) {
        for ((try c.facts.publication(Contract.library)).files) |each| if (each.eql(origin.file)) return call.ast.params[0];
    };
    return null;
}

/// The comparisons `condition` gives where it is `truth`, and still holds at `use`.
fn held(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), condition: Ast.Node.Index, truth: bool, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const tag = tree.nodeTag(condition);
    switch (tag) {
        .grouped_expression => return held(c, file, out, tree.nodeData(condition).node_and_token[0], truth, use),
        .bool_not => return held(c, file, out, tree.nodeData(condition).node, !truth, use),
        .bool_and, .bool_or => {
            // Both sides hold where `a and b` does, and neither where `a or b` fails.
            if ((tag == .bool_and) != truth) return;
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            try held(c, file, out, lhs, truth, use);
            try held(c, file, out, rhs, truth, use);
        },
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            if (!try kept(c, file, lhs, condition, use) or !try kept(c, file, rhs, condition, use)) return;
            const facts_of: []const Fact = switch (tag) {
                .less_than => if (truth) &.{.{ .small = lhs, .large = rhs, .strict = true }} else &.{.{ .small = rhs, .large = lhs, .strict = false }},
                .less_or_equal => if (truth) &.{.{ .small = lhs, .large = rhs, .strict = false }} else &.{.{ .small = rhs, .large = lhs, .strict = true }},
                .greater_than => if (truth) &.{.{ .small = rhs, .large = lhs, .strict = true }} else &.{.{ .small = lhs, .large = rhs, .strict = false }},
                .greater_or_equal => if (truth) &.{.{ .small = rhs, .large = lhs, .strict = false }} else &.{.{ .small = lhs, .large = rhs, .strict = true }},
                .equal_equal, .bang_equal => if (truth == (tag == .equal_equal))
                    &.{ .{ .small = lhs, .large = rhs, .strict = false }, .{ .small = rhs, .large = lhs, .strict = false } }
                    // An unsigned value other than zero is at least one.
                else if (literal(tree, rhs) == 0 and try unsignedAt(c, file, lhs))
                    &.{.{ .small = rhs, .large = lhs, .strict = true }}
                else if (literal(tree, lhs) == 0 and try unsignedAt(c, file, rhs))
                    &.{.{ .small = lhs, .large = rhs, .strict = true }}
                else
                    &.{},
                else => unreachable,
            };
            try out.appendSlice(c.allocator, facts_of);
        },
        else => {},
    }
}

/// Whether `node` is of an unsigned integer type at every pointer width.
fn unsignedAt(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    for (pointers) |pointer| switch (try typeOf(c, file, node, pointer, 0)) {
        .int => |int| if (int.signed) return false,
        else => return false,
    };
    return true;
}

/// Whether a statement leaves its block: a `return`, `break` or `continue`, `unreachable` or
/// `@panic`, or a block that ends in one.
fn leaves(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => return true,
        .builtin_call_two, .builtin_call_two_comma => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@panic"),
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node).?;
            return statements.len > 0 and leaves(tree, statements[statements.len - 1]);
        },
        else => return false,
    }
}

/// Whether nothing between a condition and a use assigns what the condition compares, or a
/// name or field it is made of (`pos` in `pos + n`).
fn kept(c: *Context, file: Project.FileId, compared: Ast.Node.Index, condition: Ast.Node.Index, use: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    if (literal(tree, compared) != null) return true;
    const from = tree.lastToken(condition);
    const to = tree.firstToken(use);
    if (to <= from) return true;
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
            const assignment: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(assignment);
            if (token <= from or token >= to) continue;
            if (mentions(tree, compared, tree.nodeData(assignment).node_and_node[0])) return false;
        },
        else => {},
    };
    return true;
}

/// Whether `whole` is spelled with `part`'s tokens in a row: a name or field it reads.
fn mentions(tree: *const Ast, whole: Ast.Node.Index, part: Ast.Node.Index) bool {
    const first = tree.firstToken(part);
    const count = tree.lastToken(part) - first + 1;
    var at = tree.firstToken(whole);
    const last = tree.lastToken(whole);
    while (at + count <= last + 1) : (at += 1) {
        for (0..count) |k| {
            const t: Ast.TokenIndex = @intCast(at + k);
            if (!std.mem.eql(u8, tree.tokenSlice(t), tree.tokenSlice(first + @as(Ast.TokenIndex, @intCast(k))))) break;
        } else return true;
    }
    return false;
}

/// A value as a sum of terms and a constant, as comparisons relate them: `pos + n - 4` is
/// `pos`, `n` and -4; `buf.len - i` is the length of `buf` less `i`. Terms are compared by
/// their spelling, so a comparison speaks of the same value where it is spelled the same.
const Linear = struct {
    terms: [max_terms]Term = undefined,
    len: u8 = 0,
    constant: i132 = 0,

    const max_terms = 6;
    /// A term: a value, or the length of the memory `node` is, taken away where `negative`.
    const Term = struct { node: Ast.Node.Index, length: bool, negative: bool };

    /// Adds `node` (takes it away where `negative`), its sums and differences spread into
    /// terms; false where it has more terms than a comparison is read with.
    fn put(self: *Linear, tree: *const Ast, node: Ast.Node.Index, negative: bool) bool {
        const at = bare(tree, node);
        switch (tree.nodeTag(at)) {
            .add, .assign_add => {
                const lhs, const rhs = tree.nodeData(at).node_and_node;
                return self.put(tree, lhs, negative) and self.put(tree, rhs, negative);
            },
            .sub, .assign_sub => {
                const lhs, const rhs = tree.nodeData(at).node_and_node;
                return self.put(tree, lhs, negative) and self.put(tree, rhs, !negative);
            },
            .negation => return self.put(tree, tree.nodeData(at).node, !negative),
            .number_literal => if (literal(tree, at)) |value| {
                self.constant += if (negative) -@as(i132, value) else value;
                return true;
            },
            .field_access => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(at).node_and_token[1]), "len")) {
                return self.term(tree, .{ .node = bare(tree, tree.nodeData(at).node_and_token[0]), .length = true, .negative = negative });
            },
            else => {},
        }
        return self.term(tree, .{ .node = at, .length = false, .negative = negative });
    }

    /// Adds the length of `memory`: of `m[a..]` the length of `m` less `a`, of `m[a..b]` the
    /// difference of its bounds.
    fn putLength(self: *Linear, tree: *const Ast, memory: Ast.Node.Index) bool {
        const at = bare(tree, memory);
        if (tree.fullSlice(at)) |slice| {
            if (slice.ast.end.unwrap()) |end| return self.put(tree, end, false) and self.put(tree, slice.ast.start, true);
            return self.putLength(tree, slice.ast.sliced) and self.put(tree, slice.ast.start, true);
        }
        return self.term(tree, .{ .node = at, .length = true, .negative = false });
    }

    fn term(self: *Linear, tree: *const Ast, t: Term) bool {
        for (self.terms[0..self.len], 0..) |each, i| {
            if (each.negative == t.negative or each.length != t.length or !same(tree, each.node, t.node)) continue;
            self.len -= 1;
            self.terms[i] = self.terms[self.len];
            return true;
        }
        if (self.len == max_terms) return false;
        self.terms[self.len] = t;
        self.len += 1;
        return true;
    }

    fn negated(self: Linear) Linear {
        var out = self;
        out.constant = -self.constant;
        for (out.terms[0..out.len]) |*each| each.negative = !each.negative;
        return out;
    }

    /// What is left of this value once what a comparison says is at least zero (`large -
    /// small`) is taken away.
    fn without(self: Linear, tree: *const Ast, fact: Fact) ?Linear {
        var out = self;
        if (!out.put(tree, fact.small, false) or !out.put(tree, fact.large, true)) return null;
        return out;
    }
};

/// The least value `value` can have at `at`: the comparisons holding there, one at a time with
/// what is left bounded by its range, or two together that leave nothing (`a <= b` and `b <=
/// c` put `c - a` at least zero); with `plain`, the terms' own ranges too. -far where nothing
/// bounds it.
fn least(c: *Context, file: Project.FileId, value: Linear, at: Ast.Node.Index, pointer: u16, depth: u8, plain: bool) Context.Error!i132 {
    const tree = &c.project.files[file.raw()].tree;
    var out: i132 = if (plain) try evaluated(c, file, value, pointer, depth) else -Interval.far;
    const holding = try facts(c, file, at);
    for (holding, 0..) |fact, i| {
        const left = value.without(tree, fact) orelse continue;
        const strict: i132 = @intFromBool(fact.strict);
        out = @max(out, strict + try evaluated(c, file, left, pointer, depth));
        if (left.len == 0) continue;
        for (holding[i + 1 ..]) |other| {
            const both = left.without(tree, other) orelse continue;
            if (both.len == 0) out = @max(out, strict + @intFromBool(other.strict) + both.constant);
        }
    }
    return clamp(out);
}

/// The least value a sum can have by its terms' own ranges, where it has at most two.
fn evaluated(c: *Context, file: Project.FileId, value: Linear, pointer: u16, depth: u8) Context.Error!i132 {
    if (value.len > 2) return -Interval.far;
    var out: i132 = value.constant;
    for (value.terms[0..value.len]) |each| {
        const range: Interval = if (each.length)
            if (try fixedLength(c, file, each.node)) |n| .exactly(n) else .{ .least = 0, .most = length(pointer) }
        else
            try bound(c, file, each.node, pointer, depth + 1);
        out +|= if (each.negative) -range.most else range.least;
    }
    return clamp(out);
}

/// The divisor `k` where `lhs - rhs` is `y - q * k` (or `k * q`) and `q` is a constant
/// holding `@divFloor(y, k)`, `@divTrunc(y, k)` or `y / k`, and whether the quotient is
/// floored (what is left is then never below zero).
fn remainder(c: *Context, file: Project.FileId, lhs: Ast.Node.Index, rhs: Ast.Node.Index) Context.Error!?struct { divisor: Ast.Node.Index, floored: bool } {
    const tree = &c.project.files[file.raw()].tree;
    if (tree.nodeTag(rhs) != .mul) return null;
    const a, const b = tree.nodeData(rhs).node_and_node;
    for ([_][2]Ast.Node.Index{ .{ a, b }, .{ b, a } }) |pair| {
        const quotient_node, const k = pair;
        if (tree.nodeTag(quotient_node) != .identifier) continue;
        const ref = c.project.models[file.raw()].reference(quotient_node) orelse continue;
        const init = (try untyped(c, .{ .file = file, .index = ref.declaration orelse continue })) orelse continue;
        const y, const by, const floored = switch (tree.nodeTag(init)) {
            .div => .{ tree.nodeData(init).node_and_node[0], tree.nodeData(init).node_and_node[1], true },
            .builtin_call_two, .builtin_call_two_comma => blk: {
                const name = tree.tokenSlice(tree.nodeMainToken(init));
                const floors = std.mem.eql(u8, name, "@divFloor");
                if (!floors and !std.mem.eql(u8, name, "@divTrunc")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, init, &buffer);
                if (args.len != 2) continue;
                break :blk .{ args[0], args[1], floors };
            },
            else => continue,
        };
        if (same(tree, y, lhs) and same(tree, by, k)) return .{ .divisor = k, .floored = floored };
    }
    return null;
}

/// Whether the function holding `node` indexes or slices memory with it: then it is a
/// position below that memory's length.
fn position(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return indexes(c, file, node, null);
}

/// Whether the function holding `node` indexes or slices memory with it (`memory` alone,
/// where given).
fn indexes(c: *Context, file: Project.FileId, node: Ast.Node.Index, memory: ?Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var function = node;
    while (tree.nodeTag(function) != .fn_decl) function = model.node_parents[@backingInt(function)] orelse return false;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .array_access, .slice_open, .slice, .slice_sentinel => {},
            else => continue,
        }
        const token = tree.nodeMainToken(at);
        if (token < first or token > last) continue;
        const into, const bounds: [2]?Ast.Node.Index = if (tag == .array_access) blk: {
            const operands = tree.nodeData(at).node_and_node;
            break :blk .{ operands[0], .{ operands[1], null } };
        } else blk: {
            const slice = tree.fullSlice(at).?;
            break :blk .{ slice.ast.sliced, .{ slice.ast.start, slice.ast.end.unwrap() } };
        };
        if (memory) |m| if (!same(tree, into, m)) continue;
        for (bounds) |each| if (each) |b| if (same(tree, b, node)) return true;
    }
    return false;
}

/// Whether `node` is a length, `x.len`.
fn isLength(tree: *const Ast, node: Ast.Node.Index) bool {
    const at = bare(tree, node);
    return tree.nodeTag(at) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(at).node_and_token[1]), "len");
}

/// Whether two expressions are spelled alike, parentheses and the conversions that keep a
/// value (`@as`, `@intCast`) aside.
fn same(tree: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    return std.mem.eql(u8, std.mem.trim(u8, tree.getNodeSource(bare(tree, a)), " "), std.mem.trim(u8, tree.getNodeSource(bare(tree, b)), " "));
}

fn bare(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .builtin_call_two, .builtin_call_two_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, at, &buffer);
            if (std.mem.eql(u8, name, "@as") and args.len == 2) {
                at = args[1];
            } else if (std.mem.eql(u8, name, "@intCast") and args.len == 1) {
                at = args[0];
            } else return at;
        },
        else => return at,
    };
}

/// Whether `index` stays within `memory` where it is read: below its length, or, as a slice's
/// end, at most it, by the comparisons that hold there (`if (i >= buf.len) return`, `i + 4 <=
/// buf.len`, `buf.len - i >= 4`, `start <= end` and `end <= buf.len` together) or by a fixed
/// array's declared length. Such a position the program has checked, and no peer's choice of
/// it reaches past the memory.
pub fn within(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    var room: Linear = .{};
    if (!room.putLength(tree, memory) or !room.put(tree, index, true)) return false;
    const need: i132 = if (end) 0 else 1;
    for (pointers) |pointer| {
        if (try least(c, file, room, index, pointer, 0, true) < need) return false;
    }
    return true;
}

/// What the comparisons holding where `node` is read put it at most: the larger sides, for a
/// sink that asks whether one is the program's own limit.
pub fn ceilings(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    var out: std.ArrayList(Ast.Node.Index) = .empty;
    for (try facts(c, file, node)) |fact| if (same(tree, fact.small, node)) try out.append(c.allocator, fact.large);
    return out.items;
}

/// The declared length of the fixed array a name holds (`var buf: [256]u8`, `const t = [_]u8{ ... }`).
fn fixedLength(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Context.Error!?u128 {
    const decl = (try c.facts.definition(file, memory)) orelse return null;
    const record = c.project.models[decl.file.raw()].declarations[decl.index];
    const decl_tree = &c.project.files[decl.file.raw()].tree;
    const type_node: ?Ast.Node.Index = switch (record.kind) {
        .variable => blk: {
            const variable = decl_tree.fullVarDecl(record.node) orelse return null;
            if (variable.ast.type_node.unwrap()) |t| break :blk t;
            const init = variable.ast.init_node.unwrap() orelse return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const literal_init = decl_tree.fullArrayInit(&buffer, init) orelse return null;
            const array_type = literal_init.ast.type_expr.unwrap() orelse return null;
            if (decl_tree.nodeTag(array_type) != .array_type) return null;
            const length_node = decl_tree.nodeData(array_type).node_and_node[0];
            if (decl_tree.nodeTag(length_node) == .identifier and std.mem.eql(u8, decl_tree.tokenSlice(decl_tree.nodeMainToken(length_node)), "_")) return literal_init.ast.elements.len;
            break :blk array_type;
        },
        .field => (decl_tree.fullContainerField(record.node) orelse return null).ast.type_expr.unwrap(),
        .parameter => null,
        else => null,
    };
    const t = type_node orelse return null;
    if (decl_tree.nodeTag(t) != .array_type and decl_tree.nodeTag(t) != .array_type_sentinel) return null;
    const length_node = if (decl_tree.nodeTag(t) == .array_type) decl_tree.nodeData(t).node_and_node[0] else decl_tree.nodeData(t).node_and_extra[0];
    return literal(decl_tree, length_node) orelse return null;
}
