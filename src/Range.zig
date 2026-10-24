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

/// The pointer widths a range is read at.
const pointers = [_]u16{ 32, 64 };
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
    for (pointers) |pointer| {
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
    for (pointers) |pointer| {
        const into = (try destination(c, file, node, pointer)) orelse return false;
        const from = switch (try typeOf(c, file, operand, pointer, 0)) {
            .int => |int| int,
            .literal => return false,
            .unknown => return false,
        };
        // A signed value may be negative, which no unsigned type holds.
        if (from.signed and !into.signed) return false;
        const magnitude = (try bound(c, file, operand, pointer, 0)) orelse return false;
        if (magnitude > into.room()) return false;
    }
    return true;
}

/// Whether a value is held to 16 bits at every pointer width: what it can be is a short's
/// count, never a peer's past it.
pub fn small(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    for (pointers) |pointer| {
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
        if (!same(tree, fact.small, node)) continue;
        out = narrower(out, try below(c, file, fact, pointer, depth + 1));
    }
    return out;
}

/// Whether `node` is of an unsigned integer type.
fn nonnegative(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!bool {
    return switch (try typeOf(c, file, node, pointer, 0)) {
        .int => |int| !int.signed,
        else => false,
    };
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
        .char_literal => return 0x10ffff,
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
            if (c.project.models[decl.file.raw()].declarations[decl.index].kind == .field) return stored(c, decl, pointer, next);
            return constant(c, decl, pointer, next);
        },
        .grouped_expression, .unwrap_optional => return bound(c, file, tree.nodeData(node).node_and_token[0], pointer, next),
        .@"try" => return bound(c, file, tree.nodeData(node).node, pointer, next),
        .negation => return bound(c, file, tree.nodeData(node).node, pointer, next),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return wider(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next));
        },
        .add, .assign_add, .assign_add_sat => {
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
        .mul, .assign_mul, .assign_mul_sat => {
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
        .shl, .assign_shl, .assign_shl_sat => {
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
        .bit_or, .bit_xor, .assign_bit_or, .assign_bit_xor => {
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
                .function => |decl| returned(c, decl, pointer, next),
                else => null,
            };
        },
    }
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
    ranges: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, ?u128) = .empty,
};
/// A store: the value it gives, read in its file, or none where its range is not read (a
/// field given by address, a destructure, wrapping arithmetic).
const Store = struct { file: Project.FileId, value: ?Ast.Node.Index };

/// What a field holds at most: the widest of its default and its stores, or null where a
/// store is not read or a value of its type is made otherwise (bytes viewed as it, a layout
/// that bytes define). A field whose stores read it again is unbounded while it is read, so
/// its type bounds it there.
fn stored(c: *Context, decl: Facts.Decl, pointer: u16, depth: u8) Context.Error!?u128 {
    const stores = try c.facts.memo(Stores);
    if (!stores.scanned) {
        stores.scanned = true;
        try scan(c, stores);
    }
    if (stores.blind) return null;
    const input = c.project.inputs[decl.file.raw()];
    if (!input.selected or input.classification == .@"test") return null;
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    // A layout bytes define (`extern`, `packed`) is any bytes a read or a cast gives it.
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, model.scopes[record.scope].node) orelse return null;
    if (container.layout_token != null) return null;
    if (stores.viewed.contains(.{ decl.file.raw(), record.scope })) return null;
    const key = .{ decl, pointer };
    if (stores.ranges.get(key)) |known| return known;
    try stores.ranges.put(c.allocator, key, null);
    var out: ?u128 = 0;
    const full = tree.fullContainerField(record.node) orelse return null;
    if (full.ast.value_expr.unwrap()) |default| out = wider(out, try bound(c, decl.file, default, pointer, depth));
    const lists = [_]?std.ArrayList(Store){ stores.by_field.get(decl), stores.by_name.get(record.name) };
    for (lists) |list| for (if (list) |l| l.items else &.{}) |store| {
        if (out == null) break;
        out = wider(out, try bound(c, store.file, store.value orelse {
            out = null;
            break;
        }, pointer, depth));
    };
    try stores.ranges.put(c.allocator, key, out);
    return out;
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
                    if (!try nonnegative(c, file, target, 64)) try storeInto(c, stores, file, target, null);
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
            stores.blind = true;
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

/// Marks the type a call views as bytes: `std.mem.asBytes(&x)`, `sliceAsBytes(xs)` and the
/// `bytesAs*`/`bytesToValue` that name it.
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
    var value = try c.facts.resolve(file, call.ast.params[0]);
    while (true) value = switch (value) {
        .optional, .error_union, .pointer, .array => |inner| inner.*,
        else => break,
    };
    switch (value) {
        .container, .instance => |k| try stores.viewed.put(c.allocator, .{ k.file.raw(), k.scope }, {}),
        .primitive, .scalar => {},
        else => stores.blind = true,
    }
}

/// Whether `node` is inside a `test` block.
fn inTest(tree: *const Ast, model: anytype, node: Ast.Node.Index) bool {
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .test_decl) return true;
    }
    return false;
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
/// where it spells one); a variable, a parameter, a field or a capture by its type alone.
fn constant(c: *Context, decl: Facts.Decl, pointer: u16, depth: u8) Context.Error!?u128 {
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    if (record.kind != .variable) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    const init = variable.ast.init_node.unwrap() orelse return null;
    return bound(c, decl.file, init, pointer, depth);
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
            if (decl) |d| if (try untyped(c, d)) |init| return typeOf(c, d.file, init, pointer, next);
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
        if (!same(tree, fact.large, lhs)) continue;
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
    const tree = &c.project.files[file.raw()].tree;
    for (pointers) |pointer| {
        if (try fixedLength(c, file, memory)) |n| {
            const most = (try bound(c, file, index, pointer, 0)) orelse return false;
            if (if (end) most <= n else most < n) continue;
        }
        var held_here = false;
        for (try facts(c, file, index)) |fact| held_here = held_here or keeps(tree, fact, index, memory, end);
        if (!held_here) return false;
    }
    return true;
}

/// Whether a fact keeps `index` within `memory`'s length (at most it, for a slice's end), in
/// the forms a parser checks a position: `i < buf.len`, `i + 4 <= buf.len`, `buf.len - i >= 4`
/// (or the check that leaves where it fails, `if (buf.len - i < 4) return`).
fn keeps(tree: *const Ast, fact: Fact, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) bool {
    if (lengthOf(tree, fact.large, memory)) {
        if (same(tree, fact.small, index)) return fact.strict or end;
        // `index + k` at most the length, `k` at least one: `index` is below it.
        const sum_node = bare(tree, fact.small);
        if (tree.nodeTag(sum_node) == .add) {
            const a, const b = tree.nodeData(sum_node).node_and_node;
            if (same(tree, a, index) and (literal(tree, b) orelse 0) >= 1) return true;
            if (same(tree, b, index) and (literal(tree, a) orelse 0) >= 1) return true;
        }
        return false;
    }
    // What is left after `index` is at least `k`, or above zero: `index` is below the length.
    const large = bare(tree, fact.large);
    if (tree.nodeTag(large) != .sub) return false;
    const whole, const taken = tree.nodeData(large).node_and_node;
    if (!lengthOf(tree, whole, memory) or !same(tree, taken, index)) return false;
    const k = literal(tree, fact.small) orelse return false;
    return k >= 1 or (k == 0 and (fact.strict or end));
}

/// Whether `node` is `memory.len`, or `m.len - a` where `memory` is `m[a..]`.
fn lengthOf(tree: *const Ast, node: Ast.Node.Index, memory: Ast.Node.Index) bool {
    const at = bare(tree, node);
    if (tree.nodeTag(at) == .sub) {
        const sliced = bare(tree, memory);
        if (tree.nodeTag(sliced) != .slice_open) return false;
        const whole, const start = tree.nodeData(at).node_and_node;
        const slice = tree.fullSlice(sliced).?;
        return same(tree, start, slice.ast.start) and lengthOf(tree, whole, slice.ast.sliced);
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
