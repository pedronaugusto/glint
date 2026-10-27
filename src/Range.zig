//! Integer ranges the flow rules read (designs/aegis.md §7): the greatest magnitude a value can have,
//! from its type (a decode's spelled type, a typed local, field or parameter, `@as` and a
//! conversion's destination), from what an expression does to the ranges of its operands,
//! and from the comparisons that hold where it is read (the branch it is in, an earlier
//! `if (end > buf.len) return`).
//! A010 reads them to decide whether arithmetic on a peer's number can overflow its type and
//! whether a conversion of input can fail; the loop, table and work sinks read a number held
//! to 16 bits as data, as a decode of 16 bits is.
//!
//! A range is read at each pointer width a package may build for, 32 and 64 bits: `usize` is
//! as wide as the target's pointer and a slice's length one bit less, so a sum of two lengths
//! never overflows `usize` and a sum of a length and a decoded `u32` does on a 32-bit target.
//! A site is clear only where it is clear at both.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Contract = @import("AegisContract.zig");
const Governed = @import("Governed.zig");
const Ast = std.zig.Ast;

/// An integer type: its width, and whether it is signed.
pub const Int = struct {
    bits: u16,
    signed: bool,

    /// The greatest magnitude the type holds.
    fn room(self: Int) u128 {
        return filled(if (self.signed) self.bits -| 1 else self.bits);
    }
};

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
};

/// The pointer widths a range is read at: those of the targets the package builds for
/// (`Config.pointer_widths`), both 32 and 64 bits where it names none.
fn widths(c: *const Context) []const u16 {
    return if (c.config.pointer_widths.len == 0) &.{ 32, 64 } else c.config.pointer_widths;
}
/// How deep a reading follows constants' initializers.
const depth_limit = 12;

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
    for (widths(c)) |pointer| {
        const typed = if (assigns) try typeOf(c, file, lhs, pointer, 0) else try typeOf(c, file, node, pointer, 0);
        const int = switch (typed) {
            .int => |int| int,
            else => return false,
        };
        const subtracts = tag == .sub or tag == .assign_sub;
        // A remainder spelled out (`y - @divFloor(y, k) * k`) is below `k` and never below 0
        // where `y` is not.
        if (tag == .sub and try remainder(c, file, lhs, rhs) != null) continue;
        // An unsigned difference is clear where what it takes away is known to be no more
        // than what it takes from.
        if (subtracts and !int.signed) {
            if (!try ordered(c, file, node, lhs, rhs, pointer)) return false;
            continue;
        }
        // A signed difference by a literal from a value known to be at least it, and a signed
        // sum of a literal and a value known to be at most the room left, stay in range: a
        // signed value's magnitude says nothing of which side it is on.
        if (int.signed and literal(tree, rhs) != null) {
            const k = literal(tree, rhs).?;
            if (subtracts and try ordered(c, file, node, lhs, rhs, pointer)) continue;
            if (!subtracts and tag != .mul and tag != .assign_mul) {
                if (try upper(c, file, lhs, node, pointer, 0)) |most| if (most +| k <= int.room()) continue;
            }
        }
        const left = (try bound(c, file, lhs, pointer, 0)) orelse return false;
        const right = (try bound(c, file, rhs, pointer, 0)) orelse return false;
        const needed = switch (tag) {
            .mul, .assign_mul => left *| right,
            else => left +| right,
        };
        if (needed > int.room()) return false;
    }
    return true;
}

/// Whether the conversion `node` (`@intCast(x)`) cannot fail: its destination holds every
/// value the operand's range does, at every pointer width.
pub fn converts(c: *Context, file: Project.FileId, node: Ast.Node.Index, operand: Ast.Node.Index) Context.Error!bool {
    for (widths(c)) |pointer| {
        const into = (try destination(c, file, node, pointer)) orelse return false;
        const from = switch (try typeOf(c, file, operand, pointer, 0)) {
            .int => |int| int,
            .literal => return false,
            .unknown => return false,
        };
        // A signed value may be negative, which no unsigned type holds, unless a comparison
        // where it is read keeps it at zero or above.
        if (from.signed and !into.signed and !try nonnegative(c, file, operand, pointer)) return false;
        const magnitude = (try bound(c, file, operand, pointer, 0)) orelse return false;
        if (magnitude > into.room()) return false;
    }
    return true;
}

/// Whether a value is held to 16 bits at every pointer width: what it can be is a short's
/// count, never a peer's past it.
pub fn small(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    for (widths(c)) |pointer| {
        const most = (try bound(c, file, node, pointer, 0)) orelse return false;
        if (most > std.math.maxInt(u16)) return false;
    }
    return true;
}

/// The greatest magnitude a value can have, or null where the reading does not know.
fn bound(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?u128 {
    if (depth > depth_limit) return null;
    const own = try operation(c, file, node, pointer, depth);
    const typed: ?u128 = switch (try typeOf(c, file, node, pointer, depth)) {
        .int => |int| int.room(),
        else => null,
    };
    var out = narrower(own, typed);
    // A comparison bounds a value's magnitude from above only where it cannot be negative.
    if (try nonnegative(c, file, node, pointer)) out = narrower(out, try upper(c, file, node, node, pointer, depth));
    return out;
}

/// What the comparisons holding at `at` (and a position's memory) put `node` at most, read
/// as a value, not a magnitude.
fn upper(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?u128 {
    const tree = &c.project.files[file.raw()].tree;
    if (tree.nodeTag(node) != .identifier and tree.nodeTag(node) != .field_access) return null;
    var out: ?u128 = null;
    // A position the function indexes or slices memory with is below a length.
    if (try position(c, file, node)) out = length(pointer);
    for (try facts(c, file, at)) |fact| {
        // `node + k` at most a value puts `node` at most that value less `k`.
        const base, const k = offset(tree, fact.small);
        if (!same(tree, base, node)) continue;
        out = narrower(out, ((try below(c, file, fact, pointer, depth + 1)) orelse continue) -| k);
    }
    return out;
}

/// Whether `node` cannot be negative: it is of an unsigned integer type, or a comparison
/// holding where it is read puts it at a literal or above (`if (x < 0) return`, `if (x > 0)`).
fn nonnegative(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!bool {
    switch (try typeOf(c, file, node, pointer, 0)) {
        .int => |int| if (!int.signed) return true,
        else => {},
    }
    const tree = &c.project.files[file.raw()].tree;
    for (try facts(c, file, node)) |fact| {
        if (literal(tree, fact.small) != null and same(tree, fact.large, node)) return true;
    }
    // What an operation makes at zero or above: `@max(x, 0)`, `@mod(x, k)` by a positive `k`
    // (its sign is the divisor's), `x & mask` by a literal mask.
    const at = bare(tree, node);
    switch (tree.nodeTag(at)) {
        .bit_and => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            return literal(tree, lhs) != null or literal(tree, rhs) != null;
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, at, &buffer);
            if (args.len != 2) return false;
            if (std.mem.eql(u8, name, "@max")) return literal(tree, args[0]) != null or literal(tree, args[1]) != null;
            if (std.mem.eql(u8, name, "@mod")) return (literal(tree, args[1]) orelse 0) > 0;
        },
        else => {},
    }
    return false;
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

/// What an expression's own operation bounds, before its type does.
fn operation(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?u128 {
    const tree = &c.project.files[file.raw()].tree;
    const next = depth + 1;
    switch (tree.nodeTag(node)) {
        .number_literal => return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
            .int => |value| value,
            else => null,
        },
        .char_literal => return literal(tree, node) orelse 0x10ffff,
        .identifier => {
            const model = &c.project.models[file.raw()];
            const ref = model.reference(node) orelse return null;
            const d = ref.declaration orelse return null;
            return constant(c, .{ .file = file, .index = d }, pointer, next);
        },
        .field_access => {
            const name = tree.tokenSlice(tree.nodeData(node).node_and_token[1]);
            // A length of memory the program holds: below half the address space.
            if (std.mem.eql(u8, name, "len")) return length(pointer);
            const decl = (try c.facts.definition(file, node)) orelse return null;
            return constant(c, decl, pointer, next);
        },
        .grouped_expression, .unwrap_optional => return bound(c, file, tree.nodeData(node).node_and_token[0], pointer, next),
        .@"try" => return bound(c, file, tree.nodeData(node).node, pointer, next),
        .negation => return bound(c, file, tree.nodeData(node).node, pointer, next),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            // A fallback that leaves (`orelse return error.Short`) gives no value.
            if (leaves(tree, rhs)) return bound(c, file, lhs, pointer, next);
            return wider(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next));
        },
        .add, .assign_add => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return sum(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next));
        },
        .sub => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const signed = switch (try typeOf(c, file, node, pointer, next)) {
                .int => |int| int.signed,
                else => return null,
            };
            // What is left of a value once its quotient by `k` is taken away (`y - @divFloor(y,
            // k) * k`) is a remainder, below `k`.
            if (try remainder(c, file, lhs, rhs)) |k| return ((try bound(c, file, k, pointer, next)) orelse return null) -| 1;
            // An unsigned difference that does not underflow is at most what it takes from.
            if (!signed) return bound(c, file, lhs, pointer, next);
            return sum(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next));
        },
        .mul => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = (try bound(c, file, lhs, pointer, next)) orelse return null;
            const right = (try bound(c, file, rhs, pointer, next)) orelse return null;
            return left *| right;
        },
        .div => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return quotient(try bound(c, file, lhs, pointer, next), literal(tree, rhs));
        },
        .mod => return ((try bound(c, file, tree.nodeData(node).node_and_node[1], pointer, next)) orelse return null) -| 1,
        .shl => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return shifted(try bound(c, file, lhs, pointer, next), literal(tree, rhs) orelse return null);
        },
        .shr => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = (try bound(c, file, lhs, pointer, next)) orelse return null;
            const by = literal(tree, rhs) orelse return left;
            return if (by >= 128) 0 else left >> @intCast(by);
        },
        .bit_and => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try bound(c, file, lhs, pointer, next);
            const right = try bound(c, file, rhs, pointer, next);
            if (left == null) return right;
            if (right == null) return left;
            return @min(left.?, right.?);
        },
        .bit_or, .bit_xor => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const most = wider(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next)) orelse return null;
            return filled(128 - @clz(most));
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(node).?;
            const then = try bound(c, file, branch.ast.then_expr, pointer, next);
            const otherwise = branch.ast.else_expr.unwrap() orelse return then;
            return wider(then, try bound(c, file, otherwise, pointer, next));
        },
        .@"switch", .switch_comma => {
            var out: ?u128 = 0;
            for (tree.fullSwitch(node).?.ast.cases) |case| {
                const full = tree.fullSwitchCase(case) orelse return null;
                out = wider(out, try bound(c, file, full.ast.target_expr, pointer, next));
            }
            return out;
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return builtin(c, file, node, pointer, next),
        else => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node) orelse return null;
            return switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |decl| (try extreme(c, file, decl, call, pointer)) orelse returned(c, decl, pointer, next),
                else => null,
            };
        },
    }
}

/// `std.math.maxInt(T)` of an integer type `T`: its greatest value, so a guard `x <=
/// std.math.maxInt(u32)` bounds `x` as a literal would.
fn extreme(c: *Context, file: Project.FileId, decl: Facts.Decl, call: Ast.full.Call, pointer: u16) Context.Error!?u128 {
    if (call.ast.params.len != 1) return null;
    for ((try Governed.declarations(c, "std", "math.maxInt")) orelse return null) |each| {
        if (!each.file.eql(decl.file) or each.index != decl.index) continue;
        const int = (try named(c, file, call.ast.params[0], pointer)) orelse return null;
        if (int.bits == 0) return 0;
        return filled(int.bits - @intFromBool(int.signed));
    }
    return null;
}

/// What a function returns at most, read once per function and pointer width: the widest of
/// its `return`s, each read in its body.
const Returns = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, ?u128) = .empty };

fn returned(c: *Context, decl: Facts.Decl, pointer: u16, depth: u8) Context.Error!?u128 {
    const memo = try c.facts.memo(Returns);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A function that reaches itself is read as unbounded while it is being read.
    try memo.map.put(c.allocator, key, null);
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const function = model.declarations[decl.index].node;
    if (tree.nodeTag(function) != .fn_decl) return null;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var out: ?u128 = 0;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last or enclosing(tree, model, node) != function) continue;
        const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
        out = wider(out, try bound(c, decl.file, value, pointer, depth));
        if (out == null) break;
    }
    try memo.map.put(c.allocator, key, out);
    return out;
}

/// The function a node is in.
fn enclosing(tree: *const Ast, model: anytype, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// What a builtin's operation bounds.
fn builtin(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?u128 {
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
    if (is(name, &.{"@intFromBool"})) return 1;
    // A count of bits in a type of at most 65535 bits.
    if (is(name, &.{ "@ctz", "@clz", "@popCount" })) return std.math.maxInt(u16);
    if (is(name, &.{ "@sizeOf", "@alignOf", "@bitSizeOf", "@offsetOf", "@bitOffsetOf" })) return length(pointer);
    if (args.len == 0) return null;
    // A conversion holds its operand's range within its destination's: `@as`'s by the type
    // it names, the others' by the type they are read into.
    if (is(name, &.{ "@as", "@intCast", "@truncate", "@abs" })) return bound(c, file, args[args.len - 1], pointer, depth);
    if (args.len != 2) return null;
    const left = try bound(c, file, args[0], pointer, depth);
    const right = try bound(c, file, args[1], pointer, depth);
    if (is(name, &.{"@min"})) {
        if (left == null) return right;
        if (right == null) return left;
        return @min(left.?, right.?);
    }
    if (is(name, &.{"@max"})) return wider(left, right);
    if (is(name, &.{ "@divFloor", "@divTrunc", "@divExact" })) return quotient(left, literal(tree, args[1]));
    if (is(name, &.{ "@mod", "@rem" })) return (right orelse return null) -| 1;
    if (is(name, &.{"@shlExact"})) return shifted(left, literal(tree, args[1]) orelse return null);
    if (is(name, &.{"@shrExact"})) {
        const by = literal(tree, args[1]) orelse return left;
        return if (by >= 128) 0 else (left orelse return null) >> @intCast(by);
    }
    return null;
}

/// What a declaration's value is bounded by: a constant's by its initializer (and its type,
/// where it spells one); a function's local variable by every value it is given; a
/// parameter, a field or a capture by its type alone.
fn constant(c: *Context, decl: Facts.Decl, pointer: u16, depth: u8) Context.Error!?u128 {
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    if (record.kind == .field) return stored(c, decl, pointer, depth);
    if (record.kind != .variable) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return assigned(c, decl, variable, pointer, depth);
    const init = variable.ast.init_node.unwrap() orelse return null;
    return bound(c, decl.file, init, pointer, depth);
}

/// What a function's local variable holds at most, read once per variable and pointer width:
/// the widest of its initializer and of each value assigned to it, every one read where it is
/// given (`null` and `undefined` give none). One added to, multiplied or shifted in place, or
/// whose address is taken, is unknown.
const Assigned = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, ?u128) = .empty };

fn assigned(c: *Context, decl: Facts.Decl, variable: Ast.full.VarDecl, pointer: u16, depth: u8) Context.Error!?u128 {
    const memo = try c.facts.memo(Assigned);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A variable given a value that reads itself is unknown while it is being read.
    try memo.map.put(c.allocator, key, null);
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const function = enclosing(tree, model, model.declarations[decl.index].node) orelse return null;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var out: ?u128 = 0;
    if (variable.ast.init_node.unwrap()) |init| if (!empty(tree, init)) {
        out = try bound(c, decl.file, init, pointer, depth);
    };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (out == null) break;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        switch (tag) {
            .address_of => if (namesDecl(model, tree, tree.nodeData(node).node, decl)) {
                out = null;
            },
            .assign => {
                const target, const value = tree.nodeData(node).node_and_node;
                if (!namesDecl(model, tree, target, decl) or empty(tree, value)) continue;
                out = wider(out, try bound(c, decl.file, value, pointer, depth));
            },
            .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
                if (namesDecl(model, tree, tree.nodeData(node).node_and_node[0], decl)) out = null;
            },
            else => {},
        }
    }
    try memo.map.put(c.allocator, key, out);
    return out;
}

/// Where the program's own files store fields, by the field's name: assignments to a field and
/// a struct literal's field values, found once for the run.
const Stores = struct {
    built: bool = false,
    sites: std.StringHashMapUnmanaged(std.ArrayList(Site)) = .empty,
    /// The names given to a call as arguments: a type a function fills by reflection (`std.json`
    /// parsing a `Config`, `bytesToValue(Header, …)`) has fields no store sets.
    arguments: std.StringHashMapUnmanaged(void) = .empty,
    /// A store's file and node: an assignment (or one that changes the field in place, or takes
    /// its address), or a struct literal's field value.
    const Site = struct { file: Project.FileId, node: Ast.Node.Index, kind: enum { assign, changes, literal } };
};

fn stores(c: *Context) Context.Error!*Stores {
    const memo = try c.facts.memo(Stores);
    if (memo.built) return memo;
    memo.built = true;
    for (c.project.files, 0..) |*f, raw| {
        if (!c.project.inputs[raw].selected) continue;
        const file: Project.FileId = .fromRaw(@intCast(raw));
        const tree = &f.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const target: Ast.Node.Index, const kind: @FieldType(Stores.Site, "kind") = switch (tag) {
                .assign => .{ tree.nodeData(node).node_and_node[0], .assign },
                .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => .{ tree.nodeData(node).node_and_node[0], .changes },
                .address_of => .{ tree.nodeData(node).node, .changes },
                else => {
                    var call_buffer: [1]Ast.Node.Index = undefined;
                    var builtin_buffer: [2]Ast.Node.Index = undefined;
                    const given: []const Ast.Node.Index = if (tree.fullCall(&call_buffer, node)) |call| call.ast.params else switch (tag) {
                        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => Facts.builtinArgs(tree, node, &builtin_buffer),
                        else => &.{},
                    };
                    for (given) |arg| {
                        const last = switch (tree.nodeTag(arg)) {
                            .identifier => tree.nodeMainToken(arg),
                            .field_access => tree.nodeData(arg).node_and_token[1],
                            else => continue,
                        };
                        try memo.arguments.put(c.allocator, tree.tokenSlice(last), {});
                    }
                    var buffer: [2]Ast.Node.Index = undefined;
                    const literal_init = tree.fullStructInit(&buffer, node) orelse continue;
                    for (literal_init.ast.fields) |value| {
                        if (tree.firstToken(value) < 2) continue;
                        try add(c, memo, tree.tokenSlice(tree.firstToken(value) - 2), .{ .file = file, .node = value, .kind = .literal });
                    }
                    continue;
                },
            };
            if (tree.nodeTag(target) != .field_access) continue;
            try add(c, memo, tree.tokenSlice(tree.nodeData(target).node_and_token[1]), .{ .file = file, .node = node, .kind = kind });
        }
    }
    return memo;
}

fn add(c: *Context, memo: *Stores, name: []const u8, site: Stores.Site) Context.Error!void {
    const entry = try memo.sites.getOrPut(c.allocator, name);
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    try entry.value_ptr.append(c.allocator, site);
}

/// What a field of a plain struct holds at most, read once per field and pointer width: the
/// widest of its default and of every value the program's own files store in it, by an
/// assignment or a struct literal, each read where it is stored. One changed in place or whose
/// address is taken is unknown, and so is a field of an `extern` or `packed` struct, whose bytes
/// a reinterpretation (`@bitCast`, a reader's `takeStruct`) sets with no store to read.
const Stored = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, ?u128) = .empty };

fn stored(c: *Context, decl: Facts.Decl, pointer: u16, depth: u8) Context.Error!?u128 {
    const memo = try c.facts.memo(Stored);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A field given a value that reads itself is unknown while it is being read.
    try memo.map.put(c.allocator, key, null);
    // Only the program's own files are read for stores: a field a dependency declares, it sets.
    if (!c.project.inputs[decl.file.raw()].selected) return null;
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    const field_decl = tree.fullContainerField(record.node) orelse return null;
    const container_node = model.scopes[record.scope].node;
    var buffer: [2]Ast.Node.Index = undefined;
    const holder = tree.fullContainerDecl(&buffer, container_node) orelse return null;
    if (holder.layout_token != null or tree.tokenTag(holder.ast.main_token) != .keyword_struct) return null;
    // A struct named as a call's argument may be filled by reflection.
    const found = try stores(c);
    const type_name = containerName(c, decl.file, container_node) orelse return null;
    if (found.arguments.contains(type_name)) return null;
    var out: ?u128 = 0;
    if (field_decl.ast.value_expr.unwrap()) |default| if (!empty(tree, default)) {
        out = try bound(c, decl.file, default, pointer, depth);
    };
    const sites = found.sites.get(record.name) orelse std.ArrayList(Stores.Site).empty;
    for (sites.items) |site| {
        if (out == null) break;
        const site_tree = &c.project.files[site.file.raw()].tree;
        switch (site.kind) {
            .assign, .changes => {
                const target = if (site_tree.nodeTag(site.node) == .address_of) site_tree.nodeData(site.node).node else site_tree.nodeData(site.node).node_and_node[0];
                const reached = (try c.facts.definition(site.file, target)) orelse continue;
                if (!std.meta.eql(reached, decl)) continue;
                if (site.kind == .changes) {
                    out = null;
                    continue;
                }
                const value = site_tree.nodeData(site.node).node_and_node[1];
                if (!empty(site_tree, value)) out = wider(out, try bound(c, site.file, value, pointer, depth));
            },
            .literal => {
                const literal_node = c.project.models[site.file.raw()].node_parents[@backingInt(site.node)] orelse continue;
                var holder_type = try c.facts.literalType(site.file, literal_node);
                while (true) holder_type = switch (holder_type) {
                    .optional, .error_union, .pointer => |inner| inner.*,
                    else => break,
                };
                const container = switch (holder_type) {
                    .container, .instance => |k| k,
                    else => continue,
                };
                const member = c.facts.member(container, record.name) orelse continue;
                if (!std.meta.eql(member, decl)) continue;
                if (!empty(site_tree, site.node)) out = wider(out, try bound(c, site.file, site.node, pointer, depth));
            },
        }
    }
    try memo.map.put(c.allocator, key, out);
    return out;
}

/// The name a container is declared by (`const Index = struct { … }`), or for a file's own
/// struct, the file's name (`Index.zig`).
fn containerName(c: *Context, file: Project.FileId, container_node: Ast.Node.Index) ?[]const u8 {
    const tree = &c.project.files[file.raw()].tree;
    if (container_node == .root) {
        const base = std.Io.Dir.path.basename(c.project.inputs[file.raw()].name);
        return if (std.mem.endsWith(u8, base, ".zig")) base[0 .. base.len - 4] else null;
    }
    const parent = c.project.models[file.raw()].node_parents[@backingInt(container_node)] orelse return null;
    const variable = tree.fullVarDecl(parent) orelse return null;
    return tree.tokenSlice(variable.ast.mut_token + 1);
}

/// Whether `node` is a name for the declaration `decl`.
fn namesDecl(model: anytype, tree: *const Ast, node: Ast.Node.Index, decl: Facts.Decl) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const ref = model.reference(node) orelse return false;
    return ref.declaration == decl.index;
}

/// Whether a value is `null` or `undefined`: no number.
fn empty(tree: *const Ast, node: Ast.Node.Index) bool {
    if (tree.nodeTag(node) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    return std.mem.eql(u8, name, "null") or std.mem.eql(u8, name, "undefined");
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
            // A fallback that leaves gives no value: the type is the unwrapped one's.
            if ((tree.nodeTag(node) == .@"orelse" or tree.nodeTag(node) == .@"catch") and leaves(tree, rhs)) return typeOf(c, file, lhs, pointer, next);
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
            // A magnitude is unsigned, as wide as its operand.
            if (std.mem.eql(u8, name, "@abs") and args.len == 1) return switch (try typeOf(c, file, args[0], pointer, next)) {
                .int => |int| .{ .int = .{ .bits = int.bits, .signed = false } },
                else => |other| other,
            };
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
            if (decl) |d| if (try untyped(c, d)) |init| return typeOf(c, d.file, init, pointer, next);
        },
        else => {},
    }
    return integer(try c.facts.resolve(file, node), pointer);
}

/// Whether an operation is on floats: an operand is a float literal or of a float type. A float
/// overflows to an infinity and divides by zero to one, never stopping the program.
pub fn floating(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, node);
    switch (tree.nodeTag(at)) {
        .number_literal => return std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(at))) == .float,
        .add, .sub, .mul, .div, .mod, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            return try floating(c, file, lhs) or try floating(c, file, rhs);
        },
        .negation => return floating(c, file, tree.nodeData(at).node),
        else => {},
    }
    var value = try c.facts.resolve(file, at);
    while (true) value = switch (value) {
        .optional, .error_union => |inner| inner.*,
        .primitive => |name| return name.len >= 2 and (name[0] == 'f' and std.ascii.isDigit(name[1])) or std.mem.eql(u8, name, "comptime_float"),
        else => return false,
    };
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
            // A branch's value is the `if`'s: its destination is the `if`'s.
            .@"if", .if_simple => {
                const branch = tree.fullIf(parent).?;
                if (branch.ast.then_expr != at and branch.ast.else_expr.unwrap() != at) return null;
                continue;
            },
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

/// A constant's value: an integer or character literal, or a sum, difference or product of
/// them (`255 * 4`, `'0'`).
fn literal(tree: *const Ast, node: Ast.Node.Index) ?u64 {
    switch (tree.nodeTag(node)) {
        .number_literal => return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
            .int => |value| value,
            else => null,
        },
        .char_literal => return switch (std.zig.string_literal.parseCharLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
            .success => |code| code,
            .failure => null,
        },
        .grouped_expression => return literal(tree, tree.nodeData(node).node_and_token[0]),
        .add, .sub, .mul => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const a = literal(tree, lhs) orelse return null;
            const b = literal(tree, rhs) orelse return null;
            return switch (tree.nodeTag(node)) {
                .add => std.math.add(u64, a, b) catch null,
                .sub => std.math.sub(u64, a, b) catch null,
                else => std.math.mul(u64, a, b) catch null,
            };
        },
        else => return null,
    }
}

fn narrower(a: ?u128, b: ?u128) ?u128 {
    const x = a orelse return b;
    const y = b orelse return a;
    return @min(x, y);
}

fn wider(a: ?u128, b: ?u128) ?u128 {
    return @max(a orelse return null, b orelse return null);
}

fn sum(a: ?u128, b: ?u128) ?u128 {
    return (a orelse return null) +| (b orelse return null);
}

fn shifted(a: ?u128, by: u64) ?u128 {
    const left = a orelse return null;
    if (left == 0) return 0;
    if (by >= 128 or left > @as(u128, std.math.maxInt(u128)) >> @intCast(by)) return std.math.maxInt(u128);
    return left << @intCast(by);
}

/// The greatest value of `bits` bits.
fn filled(bits: u16) u128 {
    return if (bits >= 128) std.math.maxInt(u128) else (@as(u128, 1) << @intCast(bits)) - 1;
}

/// The greatest length of memory at a pointer width: below half the address space.
fn length(pointer: u16) u128 {
    return filled(pointer - 1);
}

/// A quotient's bound: the dividend's divided by a literal divisor.
fn quotient(dividend: ?u128, divisor: ?u64) ?u128 {
    const left = dividend orelse return null;
    const by = divisor orelse return left;
    if (by == 0) return left;
    return left / by;
}

/// A comparison that holds where a value is read: `small` below `large`, or at most it.
const Fact = struct { small: Ast.Node.Index, large: Ast.Node.Index, strict: bool };

/// The comparisons that hold where `node` is evaluated: the conditions of the branches and
/// loops it is in and of the `and` and `or` it is the right side of, and the negated
/// conditions of the earlier statements of its blocks that leave when they hold (`if (end >
/// buf.len) return error.Short;`). A comparison holds while nothing between it and `node`
/// assigns what it compares.
fn facts(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Fact {
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
                    try limited(c, file, &out, statement, node);
                    const branch = tree.fullIf(statement) orelse continue;
                    if (branch.ast.else_expr != .none) continue;
                    if (leaves(tree, branch.ast.then_expr)) {
                        try held(c, file, &out, branch.ast.cond_expr, false, node);
                    } else try clamped(c, file, &out, branch, statement, node);
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
    return out.items;
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
                else if (literal(tree, rhs) == 0)
                    // An unsigned value other than zero is at least one.
                    &.{.{ .small = rhs, .large = lhs, .strict = true }}
                else if (literal(tree, lhs) == 0)
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

/// The comparison an aegis `bounded.Limit` check leaves where it passed: `try limit.check(n)`,
/// `limit.check(n) catch return …` and `if (limit.exceeds(n)) return …` put `n` at most the
/// limit, while nothing after assigns either.
fn limited(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const checked: Ast.Node.Index, const method: []const u8 = switch (tree.nodeTag(statement)) {
        .@"try" => .{ tree.nodeData(statement).node, "check" },
        .@"catch" => blk: {
            const lhs, const rhs = tree.nodeData(statement).node_and_node;
            if (!leaves(tree, rhs)) return;
            break :blk .{ lhs, "check" };
        },
        else => blk: {
            const branch = tree.fullIf(statement) orelse return;
            if (branch.ast.else_expr != .none or !leaves(tree, branch.ast.then_expr)) return;
            break :blk .{ branch.ast.cond_expr, "exceeds" };
        },
    };
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, checked) orelse return;
    if (call.ast.params.len != 1 or tree.nodeTag(call.ast.fn_expr) != .field_access) return;
    const receiver, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(name), method)) return;
    if (try c.role(Contract.library, try c.facts.resolve(file, receiver)) != .limit) return;
    const amount = call.ast.params[0];
    if (!try kept(c, file, amount, statement, use) or !try kept(c, file, receiver, statement, use)) return;
    try out.append(c.allocator, .{ .small = amount, .large = receiver, .strict = false });
}

/// The comparison a clamp leaves where it is done: `if (x > y) x = y;` puts `x` at most `y`
/// after it, and `if (x < y) x = y;` at least `y`, while nothing after assigns either.
fn clamped(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), branch: Ast.full.If, statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    var then = branch.ast.then_expr;
    switch (tree.nodeTag(then)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, then).?;
            if (statements.len != 1) return;
            then = statements[0];
        },
        else => {},
    }
    if (tree.nodeTag(then) != .assign) return;
    const target, const value = tree.nodeData(then).node_and_node;
    const condition = bare(tree, branch.ast.cond_expr);
    const lhs, const rhs = switch (tree.nodeTag(condition)) {
        .greater_than, .greater_or_equal, .less_than, .less_or_equal => tree.nodeData(condition).node_and_node,
        else => return,
    };
    const above, const under = switch (tree.nodeTag(condition)) {
        .greater_than, .greater_or_equal => .{ lhs, rhs },
        else => .{ rhs, lhs },
    };
    const fact: Fact = if (same(tree, target, above) and same(tree, value, under))
        .{ .small = target, .large = value, .strict = false }
    else if (same(tree, target, under) and same(tree, value, above))
        .{ .small = value, .large = target, .strict = false }
    else
        return;
    if (!try kept(c, file, target, statement, use) or !try kept(c, file, value, statement, use)) return;
    try out.append(c.allocator, fact);
}

/// Whether a statement leaves its block: a `return`, `break` or `continue`, `unreachable`, or
/// a block that ends in one.
fn leaves(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .@"return", .@"break", .@"continue", .unreachable_literal => return true,
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node).?;
            return statements.len > 0 and leaves(tree, statements[statements.len - 1]);
        },
        else => return false,
    }
}

/// Whether nothing between a condition and a use assigns what the condition compares.
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
            // A use inside the assignment is read before its store (`x &= x - 1`).
            if (to <= tree.lastToken(assignment)) continue;
            if (same(tree, tree.nodeData(assignment).node_and_node[0], compared)) return false;
        },
        else => {},
    };
    return true;
}

/// The bound a fact gives its smaller side: the larger side's, one less where it is strictly
/// under it.
fn below(c: *Context, file: Project.FileId, fact: Fact, pointer: u16, depth: u8) Context.Error!?u128 {
    const most = (try bound(c, file, fact.large, pointer, depth)) orelse return null;
    return if (fact.strict) most -| 1 else most;
}

/// Whether a difference `lhs - rhs` cannot go below zero: a comparison that holds there puts
/// `rhs` at most `lhs` (or a literal `rhs` at most what `lhs` is known to be at least), `rhs`
/// is a position into the memory whose length `lhs` is, or a literal `lhs` is at least all an
/// unsigned `rhs` can be.
fn ordered(c: *Context, file: Project.FileId, node: Ast.Node.Index, lhs: Ast.Node.Index, rhs: Ast.Node.Index, pointer: u16) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    if (literal(tree, rhs) == 0) return true;
    // A literal less what is known to be at most it (`8 - bit % 8`).
    if (literal(tree, lhs)) |k| {
        if (try nonnegative(c, file, rhs, pointer)) if (try bound(c, file, rhs, pointer, 0)) |most| if (most <= k) return true;
    }
    if (tree.nodeTag(lhs) == .field_access and std.mem.eql(u8, tree.tokenSlice(tree.nodeData(lhs).node_and_token[1]), "len")) {
        if (try indexes(c, file, rhs, tree.nodeData(lhs).node_and_token[0])) return true;
    }
    const taken = literal(tree, rhs);
    for (try facts(c, file, node)) |fact| {
        if (!same(tree, fact.large, lhs)) {
            // At most what is left of `lhs` once something is taken from it (`if (size > end -
            // header_len) return`): at most `lhs`.
            const large = bare(tree, fact.large);
            if (tree.nodeTag(large) == .sub and same(tree, tree.nodeData(large).node_and_node[0], lhs) and same(tree, fact.small, rhs)) return true;
            continue;
        }
        if (same(tree, fact.small, rhs)) return true;
        const k = taken orelse continue;
        const least = literal(tree, fact.small) orelse continue;
        if ((if (fact.strict) least +| 1 else least) >= k) return true;
    }
    return false;
}

/// The divisor `k` where `lhs - rhs` is `y - q * k` (or `k * q`) and `q` is a constant
/// holding `@divFloor(y, k)`, `@divTrunc(y, k)` or `y / k`.
fn remainder(c: *Context, file: Project.FileId, lhs: Ast.Node.Index, rhs: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    if (tree.nodeTag(rhs) != .mul) return null;
    const a, const b = tree.nodeData(rhs).node_and_node;
    for ([_][2]Ast.Node.Index{ .{ a, b }, .{ b, a } }) |pair| {
        const quotient_node, const k = pair;
        if (tree.nodeTag(quotient_node) != .identifier) continue;
        const ref = c.project.models[file.raw()].reference(quotient_node) orelse continue;
        const init = (try untyped(c, .{ .file = file, .index = ref.declaration orelse continue })) orelse continue;
        const y, const by = switch (tree.nodeTag(init)) {
            .div => tree.nodeData(init).node_and_node,
            .builtin_call_two, .builtin_call_two_comma => blk: {
                const name = tree.tokenSlice(tree.nodeMainToken(init));
                if (!std.mem.eql(u8, name, "@divFloor") and !std.mem.eql(u8, name, "@divTrunc")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, init, &buffer);
                if (args.len != 2) continue;
                break :blk .{ args[0], args[1] };
            },
            else => continue,
        };
        if (same(tree, y, lhs) and same(tree, by, k)) return k;
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

/// The value a constant local is another name for (`const off: usize = @intCast(at);`, `const
/// n = buf.len;`), where that value is a parameter's or a constant's, read through fields:
/// what holds for it holds for the name, since neither is assigned again.
fn alias(c: *Context, file: Project.FileId, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    const variable = constantOf(c, file, bare(tree, node)) orelse return null;
    const init = bare(tree, variable.ast.init_node.unwrap() orelse return null);
    var base = init;
    while (tree.nodeTag(base) == .field_access) base = tree.nodeData(base).node_and_token[0];
    if (tree.nodeTag(base) != .identifier) return null;
    const ref = c.project.models[file.raw()].reference(base) orelse return null;
    const d = ref.declaration orelse return null;
    const kind = c.project.models[file.raw()].declarations[d].kind;
    if (kind != .parameter and constantOf(c, file, base) == null) return null;
    return init;
}

/// The constant local an identifier names.
fn constantOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) ?Ast.full.VarDecl {
    const tree = &c.project.files[file.raw()].tree;
    if (tree.nodeTag(node) != .identifier) return null;
    const model = &c.project.models[file.raw()];
    const d = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[d];
    if (record.kind != .variable) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return variable;
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

/// Whether the comparisons holding where `index` is read keep it within `memory`: below its
/// length (`if (i >= buf.len) return`), or, as a slice's end, at most it; or below a fixed
/// array's declared length. Such a position the program has checked, and no peer's choice
/// of it reaches past the memory.
pub fn within(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    for (widths(c)) |pointer| {
        if (try fixedLength(c, file, memory)) |n| {
            const most = (try bound(c, file, index, pointer, 0)) orelse return false;
            if (if (end) most <= n else most < n) continue;
        }
        var held_here = false;
        for (try facts(c, file, index)) |fact| held_here = held_here or keeps(c, file, fact, index, memory, end);
        if (!held_here) return false;
    }
    return true;
}

/// Whether a slice's start is at most its end: `b[e - n .. e]` where the difference cannot
/// underflow, or a comparison holding there puts the start at most the end (`if (at >= t.size)
/// return null;` before `b[at..t.size]`). Such a start is within the memory wherever the end
/// is, so the end is the bound to judge.
pub fn notAfter(c: *Context, file: Project.FileId, start: Ast.Node.Index, end: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, start);
    if (tree.nodeTag(at) == .sub) {
        const lhs, const rhs = tree.nodeData(at).node_and_node;
        if (oneValue(c, file, lhs, end)) {
            for (widths(c)) |pointer| if (!try ordered(c, file, at, lhs, rhs, pointer)) return false;
            return true;
        }
    }
    for (try facts(c, file, start)) |fact| {
        if (oneValue(c, file, fact.small, start) and oneValue(c, file, fact.large, end)) return true;
    }
    return false;
}

/// Whether a fact keeps `index` within `memory`'s length (at most it, for a slice's end), in
/// the forms a parser checks a position: `i < buf.len`, `i + 4 <= buf.len`, `buf.len - i >= 4`
/// (or the check that leaves where it fails, `if (buf.len - i < 4) return`). A constant local
/// naming the index or the length (`const off = at;`, `const n = buf.len;`) is read as it.
fn keeps(c: *Context, file: Project.FileId, fact: Fact, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) bool {
    const tree = &c.project.files[file.raw()].tree;
    if (lengthOf(c, file, fact.large, memory)) {
        // `a + k` at most the length: `a + j` is within it for `j` up to `k` (below `k`, for a
        // position against a length it may reach), `a` itself for `j` of zero.
        const small_base, const k = offset(tree, fact.small);
        const index_base, const j = offset(tree, index);
        if (!oneValue(c, file, index_base, small_base)) return false;
        return if (end or fact.strict) j <= k else j < k;
    }
    // What is left after `index` is at least `k`, or above zero: `index` is below the length.
    const large = bare(tree, fact.large);
    if (tree.nodeTag(large) != .sub) return false;
    const whole, const taken = tree.nodeData(large).node_and_node;
    if (!lengthOf(c, file, whole, memory) or !oneValue(c, file, index, taken)) return false;
    const k = literal(tree, fact.small) orelse return false;
    return k >= 1 or (k == 0 and (fact.strict or end));
}

/// An expression as a base and a constant added to it: `a + 4` is `a` and 4, `a` is `a` and 0.
fn offset(tree: *const Ast, node: Ast.Node.Index) struct { Ast.Node.Index, u64 } {
    const at = bare(tree, node);
    if (tree.nodeTag(at) == .add) {
        const a, const b = tree.nodeData(at).node_and_node;
        if (literal(tree, b)) |k| return .{ a, k };
        if (literal(tree, a)) |k| return .{ b, k };
    }
    return .{ at, 0 };
}

/// Whether `a` and `b` are one value: spelled alike, or one a constant local naming the other.
fn oneValue(c: *Context, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const tree = &c.project.files[file.raw()].tree;
    if (same(tree, a, b)) return true;
    if (alias(c, file, a)) |x| if (same(tree, x, b)) return true;
    if (alias(c, file, b)) |y| if (same(tree, a, y)) return true;
    return false;
}

/// Whether `node` is `memory.len`, or `m.len - a` where `memory` is `m[a..]`, or a constant
/// local naming one.
fn lengthOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, memory: Ast.Node.Index) bool {
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, node);
    if (tree.nodeTag(at) == .sub) {
        const sliced = bare(tree, memory);
        if (tree.nodeTag(sliced) != .slice_open) return false;
        const whole, const start = tree.nodeData(at).node_and_node;
        const slice = tree.fullSlice(sliced).?;
        return same(tree, start, slice.ast.start) and lengthOf(c, file, whole, slice.ast.sliced);
    }
    if (tree.nodeTag(at) == .identifier) {
        const named_value = alias(c, file, at) orelse return false;
        return lengthOf(c, file, named_value, memory);
    }
    if (tree.nodeTag(at) != .field_access) return false;
    const receiver, const name = tree.nodeData(at).node_and_token;
    return std.mem.eql(u8, tree.tokenSlice(name), "len") and same(tree, receiver, memory);
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
