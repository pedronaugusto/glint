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
    if (!assigns and try evaluatedBefore(c, file, node)) return true;
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
    try keep(c, .{ .bounds = key });
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
    if (tag == .identifier or tag == .field_access) if (try latest(c, file, node, pointer, depth)) |given| {
        const both = r.meet(given);
        if (!both.empty()) r = both;
    };
    return if (r.empty()) out else r;
}

/// What the latest store to `node` before it gives, where that store is a statement of a block
/// `node` is in and nothing has touched the value since: `s.bits &= 7;` puts `s.bits` at most 7
/// until it is stored again, its address is taken or a call is given it.
fn latest(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?Interval {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .fn_decl => return null,
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                const statements = tree.blockStatements(&buffer, parent).?;
                var k = std.mem.findScalar(Ast.Node.Index, statements, at) orelse continue;
                while (k > 0) {
                    k -= 1;
                    const statement = statements[k];
                    const value: Interval = switch (tree.nodeTag(statement)) {
                        .assign => blk: {
                            const target, const given = tree.nodeData(statement).node_and_node;
                            if (!same(tree, target, node)) continue;
                            break :blk try bound(c, file, given, pointer, depth + 1);
                        },
                        // A mask by a value never below zero leaves at most it.
                        .assign_bit_and => blk: {
                            const target, const mask = tree.nodeData(statement).node_and_node;
                            if (!same(tree, target, node)) continue;
                            const by = try bound(c, file, mask, pointer, depth + 1);
                            if (by.least < 0) return null;
                            break :blk .{ .least = 0, .most = by.most };
                        },
                        else => continue,
                    };
                    return if (touched(c, file, node, statement, node)) null else value;
                }
            },
            else => {},
        }
    }
    return null;
}

/// Whether something may change `target` after statement `from` and before `use`: a store to
/// it or to what it is read through, its address taken, or a call given it or called on it,
/// between them or in a loop that holds `use` and begins after `from` (which runs again before
/// `use` on its next pass).
fn touched(c: *Context, file: Project.FileId, target: Ast.Node.Index, from: Ast.Node.Index, use: Ast.Node.Index) bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const after = tree.lastToken(from);
    const before = tree.firstToken(use);
    const limit = reach(tree, model, after, use);
    const root = root: {
        var at = bare(tree, target);
        while (tree.nodeTag(at) == .field_access) at = bare(tree, tree.nodeData(at).node_and_token[0]);
        break :root at;
    };
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token <= after or token > limit) continue;
        const touches = switch (tag) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => blk: {
                const lhs = tree.nodeData(node).node_and_node[0];
                break :blk mentions(tree, target, lhs) or mentions(tree, lhs, target);
            },
            .assign_destructure => blk: {
                for (tree.assignDestructure(node).ast.variables) |each| if (mentions(tree, target, each) or mentions(tree, each, target)) break :blk true;
                break :blk false;
            },
            .address_of => mentions(tree, tree.nodeData(node).node, root),
            else => blk: {
                var buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&buffer, node) orelse continue;
                if (tree.nodeTag(call.ast.fn_expr) == .field_access and mentions(tree, tree.nodeData(call.ast.fn_expr).node_and_token[0], root)) break :blk true;
                for (call.ast.params) |param| if (mentions(tree, param, root)) break :blk true;
                break :blk false;
            },
        };
        if (!touches) continue;
        if (token < before) return true;
        var up = node;
        while (model.node_parents[@backingInt(up)]) |parent| : (up = parent) {
            if (tree.nodeTag(parent) == .fn_decl) break;
            if (tree.fullWhile(parent) == null and tree.fullFor(parent) == null) continue;
            if (tree.firstToken(parent) > after and tree.firstToken(parent) <= before and tree.lastToken(parent) >= before) return true;
        }
    }
    return false;
}

/// Whether arithmetic spelled as `node` was evaluated before it on every path, with nothing it
/// is made of assigned since: in a comparison that is the condition of a branch or loop `node`
/// is in, or of an earlier `if` among its blocks' statements (`if (x > w - a) x = w - a`). A
/// value that overflows stops the program there first, at the site that is read.
fn evaluatedBefore(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .fn_decl => break,
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.blockStatements(&buffer, parent).?) |statement| {
                    if (statement == at) break;
                    const branch = tree.fullIf(statement) orelse continue;
                    if (try evaluatedIn(c, file, branch.ast.cond_expr, node)) return true;
                }
            },
            else => {
                if (tree.fullIf(parent)) |branch| {
                    if (branch.ast.cond_expr != at and try evaluatedIn(c, file, branch.ast.cond_expr, node)) return true;
                } else if (tree.fullWhile(parent)) |loop| {
                    if (loop.ast.cond_expr != at and try evaluatedIn(c, file, loop.ast.cond_expr, node)) return true;
                }
            },
        }
    }
    return false;
}

/// Whether `condition` evaluates arithmetic spelled as `node` whenever it is evaluated: in a
/// comparison's operands, or the left side of an `and` or `or`, which always runs.
fn evaluatedIn(c: *Context, file: Project.FileId, condition: Ast.Node.Index, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const tag = tree.nodeTag(condition);
    switch (tag) {
        .grouped_expression => return evaluatedIn(c, file, tree.nodeData(condition).node_and_token[0], node),
        .bool_not => return evaluatedIn(c, file, tree.nodeData(condition).node, node),
        .bool_and, .bool_or => return evaluatedIn(c, file, tree.nodeData(condition).node_and_node[0], node),
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => {},
        else => return false,
    }
    const first = tree.firstToken(condition);
    const last = tree.lastToken(condition);
    const wanted = tree.nodeTag(node);
    for (tree.nodes.items(.tag), 0..) |each, i| {
        if (each != wanted) continue;
        const earlier: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(earlier);
        if (token < first or token > last or !same(tree, earlier, node)) continue;
        if (try kept(c, file, earlier, condition, node)) return true;
    }
    return false;
}

/// Whether `side` of a loop's condition is a counter the loop raises toward the other side:
/// spelled with at least one name or field the loop adds at least one to on every pass (in its
/// continue expression or a statement of its body) and stores into in no other way, and with
/// nothing else it is made of stored into in the loop. The other side then decides how long it
/// runs.
pub fn rises(c: *Context, file: Project.FileId, loop_node: Ast.Node.Index, side: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const loop = tree.fullWhile(loop_node) orelse return false;
    var value: Linear = .{};
    if (!value.put(tree, side, false)) return false;
    var raised = false;
    for (value.terms[0..value.len]) |each| {
        const node = each.node orelse return false;
        if (each.negative) return false;
        switch (try stepped(c, file, loop, node)) {
            .kept => {},
            .raised => raised = true,
            .other => return false,
        }
    }
    return raised;
}

/// How a loop stores into `target`: never, only by adding at least one on every pass, or
/// otherwise.
fn stepped(c: *Context, file: Project.FileId, loop: Ast.full.While, target: Ast.Node.Index) Context.Error!enum { kept, raised, other } {
    const tree = &c.project.files[file.raw()].tree;
    const first = tree.firstToken(loop.ast.cond_expr);
    const last = tree.lastToken(loop.ast.then_expr);
    var buffer: [2]Ast.Node.Index = undefined;
    const body: []const Ast.Node.Index = switch (tree.nodeTag(loop.ast.then_expr)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => tree.blockStatements(&buffer, loop.ast.then_expr).?,
        else => &.{loop.ast.then_expr},
    };
    var raised = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        switch (tag) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
                const lhs, const given = tree.nodeData(node).node_and_node;
                if (!mentions(tree, target, lhs) and !mentions(tree, lhs, target)) continue;
                if (tag != .assign_add or !same(tree, lhs, target)) return .other;
                const every_pass = loop.ast.cont_expr.unwrap() == node or std.mem.findScalar(Ast.Node.Index, body, node) != null;
                if (!every_pass) return .other;
                for (pointers) |pointer| if ((try bound(c, file, given, pointer, 0)).least < 1) return .other;
                raised = true;
            },
            .assign_destructure => for (tree.assignDestructure(node).ast.variables) |each| {
                if (mentions(tree, target, each) or mentions(tree, each, target)) return .other;
            },
            .address_of => if (mentions(tree, tree.nodeData(node).node, target) or mentions(tree, target, tree.nodeData(node).node)) return .other,
            else => {},
        }
    }
    return if (raised) .raised else .kept;
}

/// Whether `node` is arithmetic on a pointer (`ptr + i`): an address, which no checked
/// overflow stops.
pub fn addresses(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    return pointerTo(c, file, tree.nodeData(node).node_and_node[0], 0);
}

/// Whether `node` is a pointer: one it resolves to, an address moved from one (`out.ptr + o`),
/// or a name with no type of its own given one.
fn pointerTo(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > depth_limit) return false;
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, node);
    if (try c.facts.resolve(file, at) == .pointer) return true;
    switch (tree.nodeTag(at)) {
        .add, .sub, .add_wrap, .sub_wrap => return pointerTo(c, file, tree.nodeData(at).node_and_node[0], depth + 1),
        .identifier => {
            const ref = c.project.models[file.raw()].reference(at) orelse return false;
            const init = (try untyped(c, .{ .file = file, .index = ref.declaration orelse return false })) orelse return false;
            return pointerTo(c, file, init, depth + 1);
        },
        else => return false,
    }
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
            const by = try shift(c, file, rhs, pointer, next);
            if (by.most >= 128) return .any;
            const out = (try bound(c, file, lhs, pointer, next)).times(.{ .least = @as(i132, 1) << @intCast(by.least), .most = @as(i132, 1) << @intCast(by.most) });
            // `<<` drops the bits it shifts out: a product past the type is not the value.
            if (tree.nodeTag(node) != .assign_shl_sat and !out.within((try typeOf(c, file, node, pointer, next)).values())) return .any;
            return out;
        },
        .shr => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const left = try bound(c, file, lhs, pointer, next);
            const by = try shift(c, file, rhs, pointer, next);
            return shiftedRight(left, by);
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

/// The bits a shift moves by: a shift amount is never below zero, and past 131 every bit is gone.
fn shift(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!Interval {
    const tree = &c.project.files[file.raw()].tree;
    const by: Interval = if (literal(tree, node)) |k| .exactly(k) else try bound(c, file, node, pointer, depth);
    const out = by.meet(.{ .least = 0, .most = 131 });
    return if (out.empty()) .{ .least = 0, .most = 131 } else out;
}

/// A value shifted right by `by` bits: toward zero, further the more it shifts.
fn shiftedRight(value: Interval, by: Interval) Interval {
    const fewest: u8 = @intCast(by.least);
    const furthest: u8 = @intCast(by.most);
    return .{
        .least = if (value.least >= 0) value.least >> furthest else value.least >> fewest,
        .most = if (value.most >= 0) value.most >> fewest else value.most >> furthest,
    };
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

/// What a function of the program returns, read once per function and pointer width: the
/// widest of its `return`s, each read in its body.
const Returns = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty };

fn returned(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const memo = try c.facts.memo(Returns);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A function that reaches itself is read as unbounded while it is being read.
    try memo.map.put(c.allocator, key, .any);
    // std's results are their types': what a reader gives is a peer's to choose.
    const input = c.project.inputs[decl.file.raw()];
    if (!input.selected or input.classification == .@"test") return .any;
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const function = definitionOf(tree, model, model.declarations[decl.index].node) orelse return .any;
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
    try keep(c, .{ .returns = key });
    return result;
}

/// The `fn_decl` a function's declaration names: the node itself, or the one its prototype heads.
fn definitionOf(tree: *const Ast, model: anytype, node: Ast.Node.Index) ?Ast.Node.Index {
    if (tree.nodeTag(node) == .fn_decl) return node;
    const parent = model.node_parents[@backingInt(node)] orelse return null;
    return if (tree.nodeTag(parent) == .fn_decl) parent else null;
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
        .parameter => passed(c, decl, pointer),
        else => .any,
    };
}

/// What each parameter holds, read once per pointer width.
const Params = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty };

/// What a parameter of a function only its own file calls holds: the widest of what its calls
/// give it, each read where the call is made. A public or exported function's parameter is its
/// type, as is one whose function is named other than to call it (given away as a value), and
/// one only tests call.
fn passed(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const memo = try c.facts.memo(Params);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A function that reaches itself gives its parameter its type while it is being read.
    try memo.map.put(c.allocator, key, .any);
    const out = try givenByCalls(c, decl, pointer);
    try memo.map.put(c.allocator, key, out);
    try keep(c, .{ .params = key });
    return out;
}

fn givenByCalls(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!Interval {
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const record = model.declarations[decl.index];
    const function: u32 = for (model.declarations, 0..) |each, i| {
        if (each.kind == .function and tree.firstToken(each.node) <= record.token and record.token <= tree.lastToken(each.node)) break @intCast(i);
    } else return .any;
    const owner = model.declarations[function];
    if (owner.public or owner.exported) return .any;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, owner.node) orelse return .any;
    var place: usize = 0;
    var it = proto.iterate(tree);
    while (it.next()) |param| : (place += 1) {
        if (param.name_token == record.token) break;
    } else return .any;
    const name = tree.tokenSlice(owner.token);
    var out: ?Interval = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const names_it = switch (tag) {
            .identifier => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name) and refersTo(model, tree, node, function),
            .field_access => std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), name) and switch (try c.facts.resolve(decl.file, node)) {
                .function => |d| d.file.eql(decl.file) and d.index == function,
                else => false,
            },
            else => false,
        };
        if (!names_it) continue;
        const parent = model.node_parents[@backingInt(node)] orelse return .any;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, parent) orelse return .any;
        if (call.ast.fn_expr != node) return .any;
        if (inTest(tree, model, parent)) continue;
        // A method called on a value takes it as its first parameter.
        var skip: usize = 0;
        if (tag == .field_access) {
            var receiver = try c.facts.resolve(decl.file, tree.nodeData(node).node_and_token[0]);
            if (receiver == .pointer) receiver = receiver.pointer.*;
            if (receiver == .instance) skip = 1;
        }
        if (place < skip or place - skip >= call.ast.params.len) return .any;
        const value = try bound(c, decl.file, call.ast.params[place - skip], pointer, 0);
        out = if (out) |o| o.join(value) else value;
    }
    return out orelse .any;
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
    /// Every struct literal of each type, by the type's file and scope.
    literals: std.AutoHashMapUnmanaged(struct { u32, u32 }, std.ArrayList(struct { file: Project.FileId, node: Ast.Node.Index })) = .empty,
    siblings: std.AutoHashMapUnmanaged(Facts.Decl, []const Sibling) = .empty,
};
/// A store: the value it gives, read in its file, or none where its range is not read (a
/// field given by address, a destructure, wrapping arithmetic); the field it is made through
/// (`x.f = v`) or the literal that makes it; and whether it only takes the field down (an
/// unsigned difference, quotient or mask), which no range reads but a relation does.
const Store = struct {
    file: Project.FileId,
    value: ?Ast.Node.Index,
    target: ?Ast.Node.Index = null,
    literal: ?Ast.Node.Index = null,
    decreases: bool = false,
};

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
            if (store.decreases) continue;
            const value = try bound(c, store.file, store.value orelse break :read .any, pointer, 0);
            out = if (out) |o| o.join(value) else value;
        };
        break :read out orelse .any;
    };
    try stores.ranges.put(c.allocator, key, result);
    try keep(c, .{ .ranges = key });
    return result;
}

/// A relation a field holds to a sibling of its instance wherever it is read: `x.name - x.f >=
/// least`, or with `length`, `x.name.len - x.f >= least`.
const Sibling = struct { decl: Facts.Decl, name: []const u8, length: bool, least: i132 };

/// The relations field `decl` holds to its integer and slice siblings (`pos <= end`, `end <=
/// buf.len`), each re-established by every store of either, read where it is made: a literal by
/// what it gives both (or their defaults), `x.f = v` by what holds of `v` and `x.g` there, `x.g
/// = w` by what holds of `w` and `x.f`; a sum that only adds to `g` keeps it. A store whose value
/// is not read, a store through a name that does not resolve, or a type made otherwise (viewed
/// as bytes, a layout bytes define) holds none.
fn siblings(c: *Context, decl: Facts.Decl) Context.Error![]const Sibling {
    const stores = try c.facts.memo(Stores);
    if (!stores.scanned) {
        stores.scanned = true;
        try scan(c, stores);
    }
    if (stores.siblings.get(decl)) |known| return known;
    // A relation is not read while it is being proved.
    try stores.siblings.put(c.allocator, decl, &.{});
    if (stores.blind) return &.{};
    const input = c.project.inputs[decl.file.raw()];
    if (!input.selected or input.classification == .@"test") return &.{};
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, model.scopes[record.scope].node) orelse return &.{};
    if (container.layout_token != null or stores.viewed.contains(.{ decl.file.raw(), record.scope })) return &.{};
    if (stores.by_name.get(record.name) != null) return &.{};
    const proving = try c.facts.memo(Proving);
    proving.depth += 1;
    const found = prove: {
        defer proving.depth -= 1;
        break :prove try siblingsOf(c, stores, decl, tree, model, record);
    };
    try stores.siblings.put(c.allocator, decl, found);
    try keep(c, .{ .siblings = decl });
    try endProof(c);
    return found;
}

fn siblingsOf(c: *Context, stores: *Stores, decl: Facts.Decl, tree: *const Ast, model: anytype, record: anytype) Context.Error![]const Sibling {
    var out: std.ArrayList(Sibling) = .empty;
    for (model.declarations, 0..) |other, o| {
        if (other.kind != .field or other.scope != record.scope or o == decl.index) continue;
        if (stores.by_name.get(other.name) != null) continue;
        const full = tree.fullContainerField(other.node) orelse continue;
        const type_node = full.ast.type_expr.unwrap() orelse continue;
        const length_of = if (tree.fullPtrType(type_node)) |ptr| ptr.size == .slice else false;
        if (!length_of and (try named(c, decl.file, type_node, 64)) == null) continue;
        const k = (try siblingLeast(c, stores, decl, .{ .file = decl.file, .index = @intCast(o) }, length_of)) orelse continue;
        try out.append(c.allocator, .{ .decl = .{ .file = decl.file, .index = @intCast(o) }, .name = other.name, .length = length_of, .least = k });
    }
    return out.toOwnedSlice(c.allocator);
}

/// Relations being proved: while one is, a reading rests on its placeholder (no relation yet).
/// What it finds is kept for the proof, which reads it again and again, and dropped when the
/// outermost proof ends, so it is read again with the relations proved.
const Proving = struct {
    depth: u32 = 0,
    kept: std.ArrayList(Kept) = .empty,

    /// A result kept during a proof, by the memo it is in.
    const Kept = union(enum) {
        bounds: struct { u32, u32, u16 },
        returns: struct { Facts.Decl, u16 },
        ranges: struct { Facts.Decl, u16 },
        constants: struct { Facts.Decl, u16 },
        locals: struct { Facts.Decl, u16 },
        grows: struct { Facts.Decl, u16 },
        siblings: Facts.Decl,
        summaries: Facts.Decl,
        params: struct { Facts.Decl, u16 },
    };
};

/// Notes a result just kept, to be dropped when the proof it was read in ends.
fn keep(c: *Context, result: Proving.Kept) Context.Error!void {
    const proving = try c.facts.memo(Proving);
    if (proving.depth > 0) try proving.kept.append(c.allocator, result);
}

/// Drops what the proofs kept, once the outermost has ended.
fn endProof(c: *Context) Context.Error!void {
    const proving = try c.facts.memo(Proving);
    if (proving.depth > 0) return;
    for (proving.kept.items) |each| switch (each) {
        .bounds => |key| _ = (try c.facts.memo(Bounds)).map.remove(key),
        .returns => |key| _ = (try c.facts.memo(Returns)).map.remove(key),
        .ranges => |key| _ = (try c.facts.memo(Stores)).ranges.remove(key),
        .constants => |key| _ = (try c.facts.memo(Constants)).bounds.remove(key),
        .locals => |key| _ = (try c.facts.memo(Constants)).locals.remove(key),
        .grows => |key| _ = (try c.facts.memo(Constants)).grows.remove(key),
        .siblings => |key| _ = (try c.facts.memo(Stores)).siblings.remove(key),
        .summaries => |key| _ = (try c.facts.memo(Summaries)).map.remove(key),
        .params => |key| _ = (try c.facts.memo(Params)).map.remove(key),
    };
    proving.kept.clearRetainingCapacity();
}

/// The least `g - f` (or `g.len - f`) every store of either leaves, or null where one does not
/// bound it.
fn siblingLeast(c: *Context, stores: *Stores, f: Facts.Decl, g: Facts.Decl, length_of: bool) Context.Error!?i132 {
    const model = &c.project.models[f.file.raw()];
    const decl_tree = &c.project.files[f.file.raw()].tree;
    const f_record = model.declarations[f.index];
    const g_record = model.declarations[g.index];
    var out: i132 = Interval.far;
    for (pointers) |pointer| {
        if (stores.literals.get(.{ f.file.raw(), f_record.scope })) |literals| for (literals.items) |made| {
            const tree = &c.project.files[made.file.raw()].tree;
            var difference: Linear = .{};
            if (literalValue(tree, made.node, g_record.name)) |given| {
                if (!(if (length_of) difference.putLength(tree, given, false) else difference.put(tree, given, false))) return null;
            } else {
                const default = (decl_tree.fullContainerField(g_record.node) orelse return null).ast.value_expr.unwrap() orelse return null;
                if (length_of) {
                    // Only an empty default's length is known: nothing.
                    if (!std.mem.eql(u8, spelled(decl_tree, default), "&.{}") and !std.mem.eql(u8, spelled(decl_tree, default), "\"\"")) return null;
                } else {
                    const given = (try bound(c, f.file, default, pointer, 0)).least;
                    if (given <= -Interval.far) return null;
                    difference.constant +|= given;
                }
            }
            if (literalValue(tree, made.node, f_record.name)) |given| {
                if (!difference.put(tree, given, true)) return null;
            } else {
                const default = (decl_tree.fullContainerField(f_record.node) orelse return null).ast.value_expr.unwrap() orelse return null;
                const given = (try bound(c, f.file, default, pointer, 0)).most;
                if (given >= Interval.far) return null;
                difference.constant -|= given;
            }
            out = @min(out, try least(c, made.file, difference, made.node, pointer, 0, true));
        };
        for ([_]Facts.Decl{ f, g }, 0..) |stored_into, side| for (if (stores.by_field.get(stored_into)) |l| l.items else &.{}) |store| {
            if (store.literal != null) continue;
            const value = store.value orelse return null;
            const target = store.target orelse return null;
            const tree = &c.project.files[store.file.raw()].tree;
            if (tree.nodeTag(target) != .field_access) return null;
            const receiver = tree.nodeData(target).node_and_token[0];
            var difference: Linear = .{};
            if (side == 0) {
                // A field that only goes down stays below what it was below.
                if (store.decreases) continue;
                const text = try c.allocator.print("{s}.{s}", .{ spelled(tree, receiver), g_record.name });
                if (!difference.term(.{ .node = null, .text = text, .length = length_of, .negative = false }) or !difference.put(tree, value, true)) return null;
            } else {
                // A sum that only adds to the larger side keeps it larger.
                if (!length_of and (tree.nodeTag(value) == .assign_add or tree.nodeTag(value) == .assign_add_sat)) {
                    if ((try bound(c, store.file, tree.nodeData(value).node_and_node[1], pointer, 0)).least >= 0) continue;
                }
                const text = try c.allocator.print("{s}.{s}", .{ spelled(tree, receiver), f_record.name });
                if (!(if (length_of) difference.putLength(tree, value, false) else difference.put(tree, value, false))) return null;
                if (!difference.term(.{ .node = null, .text = text, .length = false, .negative = true })) return null;
            }
            out = @min(out, try least(c, store.file, difference, value, pointer, 0, true));
        };
    }
    if (out >= Interval.far or out <= -Interval.far) return null;
    return out;
}

/// What a struct literal gives the field named `name`.
fn literalValue(tree: *const Ast, literal_node: Ast.Node.Index, name: []const u8) ?Ast.Node.Index {
    var buffer: [2]Ast.Node.Index = undefined;
    const init = tree.fullStructInit(&buffer, literal_node) orelse return null;
    for (init.ast.fields) |value| {
        if (tree.firstToken(value) < 2) continue;
        if (std.mem.eql(u8, tree.tokenSlice(tree.firstToken(value) - 2), name)) return value;
    }
    return null;
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
                    try storeInto(c, stores, file, target, value, false);
                },
                .assign_add, .assign_add_sat, .assign_mul, .assign_mul_sat, .assign_shl, .assign_shl_sat, .assign_bit_or, .assign_bit_xor => try storeInto(c, stores, file, tree.nodeData(node).node_and_node[0], node, false),
                .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap => try storeInto(c, stores, file, tree.nodeData(node).node_and_node[0], null, false),
                // A difference, quotient, shift right or remainder never takes an unsigned
                // value past what it was; a signed one may cross to a larger magnitude.
                .assign_sub, .assign_sub_sat, .assign_div, .assign_shr, .assign_mod, .assign_bit_and => {
                    const target = tree.nodeData(node).node_and_node[0];
                    if (try unsignedAt(c, file, target)) try storeInto(c, stores, file, target, node, true) else try storeInto(c, stores, file, target, null, false);
                },
                .assign_destructure => for (tree.assignDestructure(node).ast.variables) |variable| try storeInto(c, stores, file, variable, null, false),
                // A field given by address is written by whoever takes it.
                .address_of => try storeInto(c, stores, file, bare(tree, tree.nodeData(node).node), null, false),
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
                    switch (holder) {
                        .container, .instance => |k| {
                            const entry = try stores.literals.getOrPut(c.allocator, .{ k.file.raw(), k.scope });
                            if (!entry.found_existing) entry.value_ptr.* = .empty;
                            try entry.value_ptr.append(c.allocator, .{ .file = file, .node = node });
                        },
                        else => {},
                    }
                    for (literal_node.ast.fields) |value| {
                        if (tree.firstToken(value) < 2) continue;
                        const name = tree.tokenSlice(tree.firstToken(value) - 2);
                        const store: Store = .{ .file = file, .value = value, .literal = node };
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
fn storeInto(c: *Context, stores: *Stores, file: Project.FileId, target: Ast.Node.Index, value: ?Ast.Node.Index, decreases: bool) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    if (inTest(tree, &c.project.models[file.raw()], target)) return;
    const store: Store = .{ .file = file, .value = value, .target = target, .decreases = decreases };
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
                const quoted = tree.tokenSlice(tree.nodeMainToken(args[1]));
                return add(c, stores, null, quoted[1 .. quoted.len - 1], store);
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
    // A count of bits: at most the operand's width (a type has at most 65535), and a count of
    // trailing or leading zeros below it where the operand is not zero.
    if (is(name, &.{ "@ctz", "@clz", "@popCount" })) {
        const bits: i132 = if (args.len == 1) switch (try typeOf(c, file, args[0], pointer, depth)) {
            .int => |int| int.bits,
            else => std.math.maxInt(u16),
        } else std.math.maxInt(u16);
        if (args.len == 1 and !is(name, &.{"@popCount"})) {
            const operand = try bound(c, file, args[0], pointer, depth);
            if (operand.least > 0 or operand.most < 0) return .{ .least = 0, .most = bits - 1 };
        }
        return .{ .least = 0, .most = bits };
    }
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
        const by = try shift(c, file, args[1], pointer, depth);
        if (by.most >= 128) return .any;
        return left.times(.{ .least = @as(i132, 1) << @intCast(by.least), .most = @as(i132, 1) << @intCast(by.most) });
    }
    if (is(name, &.{"@shrExact"})) return shiftedRight(left, try shift(c, file, args[1], pointer, depth));
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
    try keep(c, .{ .constants = key });
    return out;
}

/// Constants' ranges and types, each read once per pointer width from its initializer, so a
/// chain of constants is read as far as it goes and the depth limit bounds one expression's
/// nesting alone; and local variables' ranges, each read once from its stores.
const Constants = struct {
    bounds: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty,
    types: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Typed) = .empty,
    locals: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, Interval) = .empty,
    grows: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, bool) = .empty,
};

/// What a local variable holds: the widest of its initializer and its function's stores into
/// it, each read where it is made (so a position advanced under `pos + n <= buf.len` holds
/// at most the length). A store of a value the comparisons there put at most the variable
/// (`if (n > max) n = max;`) never takes it past what it held, only down to that value's least,
/// and one of a value put at least it, only up to its greatest. A store that reads the variable without a comparison bounding it
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
                const value = try bound(c, decl.file, given, pointer, 0);
                if (out == null) break :blk value;
                var lowered: Linear = .{};
                if (!lowered.put(tree, target, false) or !lowered.put(tree, given, true)) break :blk value;
                if (try least(c, decl.file, lowered, node, pointer, 0, false) >= 0) break :blk .{ .least = value.least, .most = -Interval.far };
                if (try least(c, decl.file, lowered.negated(), node, pointer, 0, false) >= 0) break :blk .{ .least = Interval.far, .most = value.most };
                break :blk value;
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
    try keep(c, .{ .locals = key });
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
            // A constant or variable with no type of its own has its initializer's: a number
            // literal's comptime type, which takes the other operand's.
            if (decl) |d| if (try untyped(c, d)) |init| return constantType(c, d, init, pointer);
        },
        else => {},
    }
    return integer(try c.facts.resolve(file, node), pointer);
}

/// A constant's or a variable's initializer, where it spells no type: a variable takes its
/// initializer's type as a constant does (`var end = data_end;`).
fn untyped(c: *Context, decl: Facts.Decl) Context.Error!?Ast.Node.Index {
    const record = c.project.models[decl.file.raw()].declarations[decl.index];
    if (record.kind != .variable) return null;
    const tree = &c.project.files[decl.file.raw()].tree;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (variable.ast.type_node.unwrap() != null) return null;
    return variable.ast.init_node.unwrap();
}

/// Whether `decl` is a `const`.
fn constantDecl(c: *Context, decl: Facts.Decl) bool {
    const tree = &c.project.files[decl.file.raw()].tree;
    const variable = tree.fullVarDecl(c.project.models[decl.file.raw()].declarations[decl.index].node) orelse return false;
    return tree.tokenTag(variable.ast.mut_token) == .keyword_const;
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
/// variable it initializes, what it is assigned to, or the function's result it returns; an
/// index or a slice's bound is a `usize`, a shift's amount the log of the shifted type's width
/// (`u6` for a `u64`), and what `@fromBackingInt` is given the backing integer of the type it
/// makes.
fn destination(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    return switch ((try readInto(c, file, node, pointer)) orelse return null) {
        .named => |n| named(c, n.file, n.node, pointer),
        .stored => |target| switch (try typeOf(c, file, target, pointer, 0)) {
            .int => |int| int,
            else => null,
        },
        .declared => |decl| switch (integer(try c.facts.declaration(decl), pointer)) {
            .int => |int| int,
            else => null,
        },
        .int => |int| int,
    };
}

/// Where a value is read into, which a conversion's result type comes from: a type expression
/// naming it, a place it is stored into (in the value's file), a declaration whose type it
/// takes, or an integer type the read fixes.
const Into = union(enum) {
    named: struct { file: Project.FileId, node: Ast.Node.Index },
    stored: Ast.Node.Index,
    declared: Facts.Decl,
    int: Int,
};

fn readInto(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!?Into {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        switch (tree.nodeTag(parent)) {
            .grouped_expression, .@"try" => continue,
            .builtin_call_two, .builtin_call_two_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(parent));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, parent, &buffer);
                if (std.mem.eql(u8, name, "@as")) {
                    if (args.len != 2 or args[1] != at) return null;
                    return .{ .named = .{ .file = file, .node = args[0] } };
                }
                if (std.mem.eql(u8, name, "@fromBackingInt") or std.mem.eql(u8, name, "@enumFromInt")) {
                    if (args.len != 1 or args[0] != at) return null;
                    const kind = (try makes(c, file, parent)) orelse return null;
                    return .{ .int = ((try backing(c, kind, pointer)) orelse return null).int };
                }
                return null;
            },
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                return .{ .stored = lhs };
            },
            .array_access => {
                if (tree.nodeData(parent).node_and_node[1] != at) return null;
                return .{ .int = .{ .bits = pointer, .signed = false } };
            },
            .shl, .shr, .assign_shl, .assign_shr => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                const shifted = switch (try typeOf(c, file, lhs, pointer, 0)) {
                    .int => |int| int,
                    else => return null,
                };
                return .{ .int = .{ .bits = if (shifted.bits <= 1) 0 else std.math.log2_int_ceil(u16, shifted.bits), .signed = false } };
            },
            .@"return" => {
                var scope = parent;
                while (model.node_parents[@backingInt(scope)]) |up| : (scope = up) {
                    if (tree.nodeTag(up) != .fn_decl) continue;
                    var buffer: [1]Ast.Node.Index = undefined;
                    const proto = tree.fullFnProto(&buffer, tree.nodeData(up).node_and_node[0]) orelse return null;
                    return .{ .named = .{ .file = file, .node = proto.ast.return_type.unwrap() orelse return null } };
                }
                return null;
            },
            else => {
                if (tree.fullVarDecl(parent)) |variable| {
                    if (variable.ast.init_node.unwrap() != at) return null;
                    return .{ .named = .{ .file = file, .node = variable.ast.type_node.unwrap() orelse return null } };
                }
                if (tree.fullSlice(parent)) |slice| {
                    if (slice.ast.start != at and slice.ast.end.unwrap() != at) return null;
                    return .{ .int = .{ .bits = pointer, .signed = false } };
                }
                var call_buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&call_buffer, parent)) |call| return argument(c, file, call, at);
                var init_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&init_buffer, parent)) |_| return field(c, file, parent, at);
                return null;
            },
        }
    }
    return null;
}

/// The parameter `arg` is given to, where the call resolves.
fn argument(c: *Context, file: Project.FileId, call: Ast.full.Call, arg: Ast.Node.Index) Context.Error!?Into {
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
        return .{ .named = .{ .file = decl.file, .node = param.type_expr orelse return null } };
    }
    return null;
}

/// The field a struct literal's `value` initializes.
fn field(c: *Context, file: Project.FileId, literal_node: Ast.Node.Index, value: Ast.Node.Index) Context.Error!?Into {
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
    return .{ .declared = decl };
}

/// The type a conversion `node` makes (`@fromBackingInt`, `@enumFromInt`), by where its
/// result is read into.
fn makes(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.Container {
    var value: Facts.Value = switch ((try readInto(c, file, node, 64)) orelse return null) {
        .named => |n| try c.facts.resolve(n.file, n.node),
        .stored => |target| try c.facts.resolve(file, target),
        .declared => |decl| try c.facts.declaration(decl),
        .int => return null,
    };
    while (true) value = switch (value) {
        .optional, .error_union => |inner| inner.*,
        else => break,
    };
    return switch (value) {
        .container, .instance => |k| k,
        else => null,
    };
}

/// A type's backing integer, and the values of it that make one: every value for a packed
/// struct and a non-exhaustive enum; for an exhaustive enum its tags', where they run from the
/// least to the greatest with none missing.
const Backing = struct { int: Int, values: Interval };

fn backing(c: *Context, kind: Facts.Container, pointer: u16) Context.Error!?Backing {
    const tree = &c.project.files[kind.file.raw()].tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = tree.fullContainerDecl(&buffer, c.project.models[kind.file.raw()].scopes[kind.scope].node) orelse return null;
    const int = (try named(c, kind.file, decl.ast.arg.unwrap() orelse return null, pointer)) orelse return null;
    switch (tree.tokenTag(decl.ast.main_token)) {
        .keyword_struct => {
            const layout = decl.layout_token orelse return null;
            return if (tree.tokenTag(layout) == .keyword_packed) .{ .int = int, .values = int.values() } else null;
        },
        .keyword_enum => {
            var next: i132 = 0;
            var tags: ?Interval = null;
            var count: i132 = 0;
            for (decl.ast.members) |member| {
                const tag = tree.fullContainerField(member) orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(tag.ast.main_token), "_")) return .{ .int = int, .values = int.values() };
                const value: i132 = if (tag.ast.value_expr.unwrap()) |v| literal(tree, v) orelse return null else next;
                tags = if (tags) |t| t.join(.exactly(value)) else .exactly(value);
                count += 1;
                next = value + 1;
            }
            const all = tags orelse return null;
            return if (all.most - all.least + 1 == count) .{ .int = int, .values = all } else null;
        },
        else => return null,
    }
}

/// Whether `@fromBackingInt(operand)` or `@enumFromInt(operand)` at `node` cannot fail: every
/// value the operand's range holds makes one of the type it makes, at every pointer width.
pub fn backs(c: *Context, file: Project.FileId, node: Ast.Node.Index, operand: Ast.Node.Index) Context.Error!bool {
    const kind = (try makes(c, file, node)) orelse return false;
    for (pointers) |pointer| {
        const values = ((try backing(c, kind, pointer)) orelse return false).values;
        if (!(try bound(c, file, operand, pointer, 0)).within(values)) return false;
    }
    return true;
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

/// A comparison that holds where a value is read: `small` below `large`, or at most it, with
/// the stores on the way that moved what it compares by an amount.
const Fact = struct { small: Ast.Node.Index, large: Ast.Node.Index, strict: bool, moved: []const Moved = &.{} };

/// A store on every path from a comparison to a read that adds `by` to `target` (takes it away
/// where `!adds`): what the comparison said of `target` it says there of `target` less `by`.
const Moved = struct { store: Ast.Node.Index, target: Ast.Node.Index, by: Ast.Node.Index, adds: bool };

/// The comparisons holding at each node, gathered once.
const Held = struct {
    map: std.AutoHashMapUnmanaged(struct { u32, u32 }, []const Fact) = .empty,
    relations: std.AutoHashMapUnmanaged(struct { u32, u32 }, []const Linear) = .empty,
};

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
            var moved: std.ArrayList(Moved) = .empty;
            if (!try carried(c, file, lhs, condition, use, &moved) or !try carried(c, file, rhs, condition, use, &moved)) return;
            const shifts = try moved.toOwnedSlice(c.allocator);
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
            const start = out.items.len;
            try out.appendSlice(c.allocator, facts_of);
            for (out.items[start..]) |*each| each.moved = shifts;
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
    // A loop's continue expression runs after its body, before the condition is read again.
    const after: ?Ast.Node.Index = loop: {
        const model = &c.project.models[file.raw()];
        var at = condition;
        while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
            if (tree.nodeTag(parent) == .grouped_expression) continue;
            const loop = tree.fullWhile(parent) orelse break :loop null;
            break :loop if (loop.ast.cond_expr == at) loop.ast.cont_expr.unwrap() else null;
        }
        break :loop null;
    };
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
            const assignment: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(assignment);
            if (token <= from or token >= to) continue;
            if (after) |cont| if (token >= tree.firstToken(cont) and token <= tree.lastToken(cont)) continue;
            if (mentions(tree, compared, tree.nodeData(assignment).node_and_node[0])) return false;
        },
        else => {},
    };
    return true;
}

/// Whether what `compared` is at `condition` is still known at `use`: nothing between them stores
/// into what it is made of, or only stores on every path between that add an amount to a name or
/// field it is spelled with (`at += n` past `if (buf.len - at < n) return`), which `moved` gathers.
fn carried(c: *Context, file: Project.FileId, compared: Ast.Node.Index, condition: Ast.Node.Index, use: Ast.Node.Index, moved: *std.ArrayList(Moved)) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    if (literal(tree, compared) != null) return true;
    const from = tree.lastToken(condition);
    const to = tree.firstToken(use);
    if (to <= from) return true;
    const after = continued(c, file, condition);
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
            const assignment: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(assignment);
            if (token <= from or token >= to) continue;
            if (after) |cont| if (token >= tree.firstToken(cont) and token <= tree.lastToken(cont)) continue;
            const target, const by = tree.nodeData(assignment).node_and_node;
            if (!mentions(tree, compared, target)) continue;
            if ((tag != .assign_add and tag != .assign_sub) or !try movable(c, file, assignment, condition, use)) return false;
            for (moved.items) |each| {
                if (each.store == assignment) break;
            } else try moved.append(c.allocator, .{ .store = assignment, .target = target, .by = by, .adds = tag == .assign_add });
        },
        else => {},
    };
    return true;
}

/// A loop's continue expression, where `condition` is the loop's condition: it runs after the
/// body, before the condition is read again.
fn continued(c: *Context, file: Project.FileId, condition: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var at = condition;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .grouped_expression) continue;
        const loop = tree.fullWhile(parent) orelse return null;
        return if (loop.ast.cond_expr == at) loop.ast.cont_expr.unwrap() else null;
    }
    return null;
}

/// Whether `store` runs on every path from `condition` to `use`, once: a statement of a block
/// `use` is in, in no loop `condition` is not in, adding an amount nothing changes before `use`
/// to a name or field that is not part of it.
fn movable(c: *Context, file: Project.FileId, store: Ast.Node.Index, condition: Ast.Node.Index, use: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const target, const by = tree.nodeData(store).node_and_node;
    switch (tree.nodeTag(bare(tree, target))) {
        .identifier, .field_access => {},
        else => return false,
    }
    if (mentions(tree, by, target)) return false;
    const block = model.node_parents[@backingInt(store)] orelse return false;
    switch (tree.nodeTag(block)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => {},
        else => return false,
    }
    if (!encloses(model, block, use)) return false;
    var up = store;
    while (model.node_parents[@backingInt(up)]) |parent| : (up = parent) {
        if (tree.nodeTag(parent) == .fn_decl) break;
        if (tree.fullWhile(parent) == null and tree.fullFor(parent) == null) continue;
        if (!encloses(model, parent, condition)) return false;
    }
    return kept(c, file, by, store, use);
}

/// Whether `outer` is `node` or holds it.
fn encloses(model: anytype, outer: Ast.Node.Index, node: Ast.Node.Index) bool {
    var at = node;
    while (true) {
        if (at == outer) return true;
        at = model.node_parents[@backingInt(at)] orelse return false;
    }
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
    /// A term: a value, or the length of the memory it is, taken away where `negative`, by its
    /// spelling; `node` spells it where the source does (a sibling field a relation names,
    /// `x.end` from a store to `x.pos`, has none).
    const Term = struct {
        node: ?Ast.Node.Index,
        text: []const u8,
        length: bool,
        negative: bool,
        /// For a sibling a relation names: the field, and the instance it is read on.
        field: ?Facts.Decl = null,
        receiver: []const u8 = "",

        fn of(tree: *const Ast, node: Ast.Node.Index, length_of: bool, negative: bool) Term {
            return .{ .node = node, .text = spelled(tree, node), .length = length_of, .negative = negative };
        }
    };

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
                self.constant +|= if (negative) -@as(i132, value) else value;
                return true;
            },
            .field_access => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeData(at).node_and_token[1]), "len")) {
                return self.term(Term.of(tree, bare(tree, tree.nodeData(at).node_and_token[0]), true, negative));
            },
            else => {},
        }
        return self.term(Term.of(tree, at, false, negative));
    }

    /// Adds the length of `memory` (takes it away where `negative`): of `m[a..]` the length of
    /// `m` less `a`, of `m[a..b]` the difference of its bounds.
    fn putLength(self: *Linear, tree: *const Ast, memory: Ast.Node.Index, negative: bool) bool {
        const at = bare(tree, memory);
        if (tree.fullSlice(at)) |slice| {
            if (slice.ast.end.unwrap()) |end| return self.put(tree, end, negative) and self.put(tree, slice.ast.start, !negative);
            return self.putLength(tree, slice.ast.sliced, negative) and self.put(tree, slice.ast.start, !negative);
        }
        return self.term(Term.of(tree, at, true, negative));
    }

    fn term(self: *Linear, t: Term) bool {
        for (self.terms[0..self.len], 0..) |each, i| {
            if (each.negative == t.negative or each.length != t.length or !std.mem.eql(u8, each.text, t.text)) continue;
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

    /// What is left of this value once `other` is taken away.
    fn less(self: Linear, other: Linear) ?Linear {
        var out = self;
        out.constant -|= other.constant;
        for (other.terms[0..other.len]) |each| {
            var flipped = each;
            flipped.negative = !each.negative;
            if (!out.term(flipped)) return null;
        }
        return out;
    }
};

/// The least value `value` can have at `at`: by the relations holding there (its comparisons,
/// and what the calls and locals it is made of give), one at a time with what is left bounded
/// by its range, or two together that leave nothing (`a <= b` and `b <= c` put `c - a` at least
/// zero); with `plain`, the terms' own ranges too. -far where nothing bounds it.
fn least(c: *Context, file: Project.FileId, value: Linear, at: Ast.Node.Index, pointer: u16, depth: u8, plain: bool) Context.Error!i132 {
    var out: i132 = if (plain) try evaluated(c, file, value, pointer, depth) else -Interval.far;
    var known: Known = .{};
    for (try relations(c, file, at)) |each| known.add(each);
    const direct = known.len;
    try definitions(c, file, value, at, pointer, &known);
    // The names that equal their initializers spelled out, for a second reading below; what the
    // initializers are made of relates too (`taken.len` is `@min(piece.len, left)`).
    const spelled_value = try expanded(c, file, value, at);
    if (spelled_value) |v| try definitions(c, file, v, at, pointer, &known);
    // What the relations just read are made of relates too, one step further (`x.pos <= x.end`
    // brings `x.end <= x.buf.len`).
    const read = known.len;
    for (direct..read) |i| try definitions(c, file, known.items[i], at, pointer, &known);
    const holding = known.items[0..known.len];
    out = @max(out, try leastBy(c, file, value, holding, pointer, depth));
    // Read again with the names that equal their initializers spelled out, in the value and the
    // relations alike: a check of `end - header_len` speaks of `bytes.len - k` where `end` still
    // holds `data_end`, and `data_end` is `bytes.len - k`.
    var spelled_out: Known = .{};
    var any = spelled_value != null;
    const flat = spelled_value orelse value;
    for (holding) |relation| spelled_out.add(if (try expanded(c, file, relation, at)) |r| blk: {
        any = true;
        break :blk r;
    } else relation);
    if (any) out = @max(out, try leastBy(c, file, flat, spelled_out.items[0..spelled_out.len], pointer, depth));
    return clamp(out);
}

/// The least value `value` can have by `holding`: one relation at a time with what is left
/// bounded by its range, or two together that leave nothing.
fn leastBy(c: *Context, file: Project.FileId, value: Linear, holding: []const Linear, pointer: u16, depth: u8) Context.Error!i132 {
    var out: i132 = -Interval.far;
    for (holding, 0..) |relation, i| {
        const left = value.less(relation) orelse continue;
        out = @max(out, try evaluated(c, file, left, pointer, depth));
        if (left.len == 0) continue;
        for (holding[i + 1 ..]) |other| {
            const both = left.less(other) orelse continue;
            if (both.len == 0) out = @max(out, both.constant);
        }
    }
    return out;
}

/// `value` with each name that equals its initializer where `at` reads it spelled as that
/// initializer, as far as the names go: a constant, or a variable nothing has stored into
/// since, whose initializer still holds at `at`; the length of a name that holds a slice as
/// the slice's. Null where no name is spelled out.
fn expanded(c: *Context, file: Project.FileId, value: Linear, at: Ast.Node.Index) Context.Error!?Linear {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var out = value;
    var changed = false;
    var steps: u8 = 0;
    spell: while (steps < max_spelled) : (steps += 1) {
        for (out.terms[0..out.len], 0..) |each, i| {
            const node = each.node orelse continue;
            if (tree.nodeTag(node) != .identifier) continue;
            const ref = model.reference(node) orelse continue;
            const index = ref.declaration orelse continue;
            const record = model.declarations[index];
            if (record.kind != .variable) continue;
            const variable = tree.fullVarDecl(record.node) orelse continue;
            const init = variable.ast.init_node.unwrap() orelse continue;
            if (each.length and tree.fullSlice(bare(tree, init)) == null) continue;
            if (!each.length and !try steady(c, file, init, 0)) continue;
            if (tree.tokenTag(variable.ast.mut_token) == .keyword_var and !unchanged(c, file, index, at)) continue;
            if (!try kept(c, file, init, record.node, at)) continue;
            var next = out;
            next.len -= 1;
            next.terms[i] = next.terms[next.len];
            if (!(if (each.length) next.putLength(tree, init, each.negative) else next.put(tree, init, each.negative))) continue;
            out = next;
            changed = true;
            continue :spell;
        }
        break;
    }
    return if (changed) out else null;
}

/// Whether `node` is a sum each of whose terms gives the same value wherever it is spelled, as
/// terms are compared by spelling: names, fields, numbers, and calls of functions that take
/// nothing by pointer (`kind.rawLen()`), not a read from a stream (`try r.takeInt(u32, 0)`),
/// which gives another value each time.
fn steady(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > depth_limit) return false;
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, node);
    switch (tree.nodeTag(at)) {
        .number_literal, .identifier => return true,
        .add, .sub, .mul => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            return try steady(c, file, lhs, depth + 1) and try steady(c, file, rhs, depth + 1);
        },
        .negation => return steady(c, file, tree.nodeData(at).node, depth + 1),
        .field_access => return steady(c, file, tree.nodeData(at).node_and_token[0], depth + 1),
        else => {},
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, at) orelse return false;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        else => return false,
    };
    if (!byValue(c, decl)) return false;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access and !try steady(c, file, tree.nodeData(call.ast.fn_expr).node_and_token[0], depth + 1)) return false;
    for (call.ast.params) |param| if (!try steady(c, file, param, depth + 1)) return false;
    return true;
}

/// Whether function `decl` takes each of its parameters by value: none is a pointer or
/// `anytype`.
fn byValue(c: *Context, decl: Facts.Decl) bool {
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const function = definitionOf(tree, model, model.declarations[decl.index].node) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return false;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        const type_node = param.type_expr orelse return false;
        if (tree.fullPtrType(type_node) != null) return false;
    }
    return true;
}

/// The last token a store can be at and still reach `use` from past token `after`: `use`'s own
/// start, or the end of the outermost loop around `use` that begins past `after` (which runs again
/// before `use` on its next pass).
fn reach(tree: *const Ast, model: anytype, after: Ast.TokenIndex, use: Ast.Node.Index) Ast.TokenIndex {
    var limit = tree.firstToken(use);
    var at = use;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) break;
        if (tree.fullWhile(parent) == null and tree.fullFor(parent) == null) continue;
        if (tree.firstToken(parent) > after) limit = @max(limit, tree.lastToken(parent));
    }
    return limit;
}

/// How many names one value is spelled out through.
const max_spelled = 8;

/// Whether nothing stores into local `index` between its declaration and `at`: no store between
/// them, none in a loop that holds `at` and began after it (which runs again before `at` is
/// reached on the next pass), and its address never taken.
fn unchanged(c: *Context, file: Project.FileId, index: u32, at: Ast.Node.Index) bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const declared_at = tree.lastToken(model.declarations[index].node);
    const use = tree.firstToken(at);
    const limit = reach(tree, model, declared_at, at);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const main = tree.nodeMainToken(node);
        if (main <= declared_at or main > limit) continue;
        switch (tag) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
                if (!refersTo(model, tree, tree.nodeData(node).node_and_node[0], index)) continue;
            },
            .assign_destructure => {
                for (tree.assignDestructure(node).ast.variables) |each| if (refersTo(model, tree, each, index)) return false;
                continue;
            },
            .address_of => {
                if (refersTo(model, tree, bare(tree, tree.nodeData(node).node), index)) return false;
                continue;
            },
            else => continue,
        }
        if (main < use) return false;
        var up = node;
        while (model.node_parents[@backingInt(up)]) |parent| : (up = parent) {
            if (tree.nodeTag(parent) == .fn_decl) break;
            if (tree.fullWhile(parent) == null and tree.fullFor(parent) == null) continue;
            if (tree.firstToken(parent) > declared_at and tree.firstToken(parent) <= use and tree.lastToken(parent) >= use) return false;
        }
    }
    return true;
}

/// Relations a reading holds at once: each a difference that is at least zero.
const Known = struct {
    items: [max]Linear = undefined,
    len: usize = 0,

    const max = 48;

    fn add(self: *Known, relation: Linear) void {
        if (self.len == max) return;
        self.items[self.len] = relation;
        self.len += 1;
    }
};

/// The comparisons holding at `node` as relations, each `large - small` (less one where strict)
/// at least zero.
fn relations(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Linear {
    const memo = try c.facts.memo(Held);
    const key = .{ file.raw(), @backingInt(node) };
    if (memo.relations.get(key)) |known| return known;
    const tree = &c.project.files[file.raw()].tree;
    var out: std.ArrayList(Linear) = .empty;
    for (try facts(c, file, node)) |fact| {
        var difference: Linear = .{};
        if (!difference.put(tree, fact.large, false) or !difference.put(tree, fact.small, true)) continue;
        difference.constant -|= @intFromBool(fact.strict);
        if (!carriedOver(tree, &difference, fact.moved)) continue;
        try out.append(c.allocator, difference);
    }
    const found = try out.toOwnedSlice(c.allocator);
    try memo.relations.put(c.allocator, key, found);
    return found;
}

/// `difference`, said of what it compares before the stores that moved it, said after them: a
/// term a store added `by` to stands for itself less `by`. False where a store moved something
/// that is no whole term.
fn carriedOver(tree: *const Ast, difference: *Linear, moved: []const Moved) bool {
    for (moved) |each| {
        const text = spelled(tree, each.target);
        var signs: [Linear.max_terms]bool = undefined;
        var count: usize = 0;
        for (difference.terms[0..difference.len]) |t| if (!t.length and std.mem.eql(u8, t.text, text)) {
            signs[count] = t.negative;
            count += 1;
        };
        if (count == 0) return false;
        for (signs[0..count]) |negative| if (!difference.put(tree, each.by, negative != each.adds)) return false;
    }
    return true;
}

/// The relations what `value` is made of gives where it is read: a call's result (or a constant
/// holding one) relates to the call's arguments by its function's summary, while nothing an
/// argument is made of is assigned since; `@min` is at most each operand and `@max` at least
/// each; a local that only grows is at least its initializer.
fn definitions(c: *Context, file: Project.FileId, value: Linear, at: Ast.Node.Index, pointer: u16, out: *Known) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    for (value.terms[0..value.len]) |each| {
        if (each.length) continue;
        // A field read relates to its instance's siblings by what every store keeps.
        if (each.field) |named_field| {
            try related(c, named_field, each.receiver, out);
            continue;
        }
        const node = each.node orelse continue;
        if (tree.nodeTag(node) == .field_access) {
            const decl = (try c.facts.definition(file, node)) orelse continue;
            if (c.project.models[decl.file.raw()].declarations[decl.index].kind != .field) continue;
            try related(c, decl, spelled(tree, tree.nodeData(node).node_and_token[0]), out);
            continue;
        }
        var source = unwrapped(tree, node);
        var named_by: ?Ast.Node.Index = null;
        if (tree.nodeTag(source) == .identifier) {
            const ref = model.reference(source) orelse continue;
            const index = ref.declaration orelse continue;
            const record = model.declarations[index];
            if (record.kind != .variable) continue;
            const variable = tree.fullVarDecl(record.node) orelse continue;
            const init = variable.ast.init_node.unwrap() orelse continue;
            if (tree.tokenTag(variable.ast.mut_token) == .keyword_var) {
                if (!try grows(c, .{ .file = file, .index = index }, pointer) or !try kept(c, file, init, record.node, at)) continue;
                var difference: Linear = .{};
                if (difference.put(tree, node, false) and difference.put(tree, init, true)) out.add(difference);
                continue;
            }
            source = unwrapped(tree, init);
            named_by = source;
        }
        if (tree.nodeTag(source) == .builtin_call_two or tree.nodeTag(source) == .builtin_call_two_comma) {
            const name = tree.tokenSlice(tree.nodeMainToken(source));
            const lower = std.mem.eql(u8, name, "@min");
            if (!lower and !std.mem.eql(u8, name, "@max")) continue;
            var args_buffer: [2]Ast.Node.Index = undefined;
            for (Facts.builtinArgs(tree, source, &args_buffer)) |arg| {
                if (named_by) |given_by| if (!try kept(c, file, arg, given_by, at)) continue;
                var difference: Linear = .{};
                if (difference.put(tree, if (lower) arg else node, false) and difference.put(tree, if (lower) node else arg, true)) out.add(difference);
            }
            continue;
        }
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, source) orelse continue;
        const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
            .function => |d| d,
            else => continue,
        };
        // A method called on a value takes it as its first parameter.
        var receiver: ?Ast.Node.Index = null;
        if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
            const lhs = tree.nodeData(call.ast.fn_expr).node_and_token[0];
            var held_value = try c.facts.resolve(file, lhs);
            if (held_value == .pointer) held_value = held_value.pointer.*;
            if (held_value == .instance) receiver = lhs;
        }
        for (try summary(c, decl)) |relation| {
            const arg = if (receiver) |r|
                (if (relation.param == 0) r else if (relation.param - 1 < call.ast.params.len) call.ast.params[relation.param - 1] else continue)
            else if (relation.param < call.ast.params.len) call.ast.params[relation.param] else continue;
            if (named_by) |given| if (!try kept(c, file, arg, given, at)) continue;
            var difference: Linear = .{};
            const spread = if (relation.length)
                difference.putLength(tree, arg, false) and difference.put(tree, node, true)
            else
                difference.put(tree, node, false) and difference.put(tree, arg, true);
            if (!spread) continue;
            difference.constant -|= relation.least;
            out.add(difference);
        }
    }
}

/// The relations field `decl` read on `receiver` holds to its siblings there.
fn related(c: *Context, decl: Facts.Decl, receiver: []const u8, out: *Known) Context.Error!void {
    const name = c.project.models[decl.file.raw()].declarations[decl.index].name;
    const self_text = try c.allocator.print("{s}.{s}", .{ receiver, name });
    for (try siblings(c, decl)) |sibling| {
        var difference: Linear = .{};
        const text = try c.allocator.print("{s}.{s}", .{ receiver, sibling.name });
        if (!difference.term(.{ .node = null, .text = text, .length = sibling.length, .negative = false, .field = sibling.decl, .receiver = receiver })) continue;
        if (!difference.term(.{ .node = null, .text = self_text, .length = false, .negative = true, .field = decl, .receiver = receiver })) continue;
        difference.constant -|= sibling.least;
        out.add(difference);
    }
}

/// A value through what keeps it: `try`, `.?`, and an `orelse` or `catch` whose other side
/// leaves or gives `null` (the value is then the left side's whenever there is one).
fn unwrapped(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = bare(tree, node);
    while (true) switch (tree.nodeTag(at)) {
        .@"try" => at = bare(tree, tree.nodeData(at).node),
        .unwrap_optional => at = bare(tree, tree.nodeData(at).node_and_token[0]),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            if (!leaves(tree, rhs) and !isNull(tree, rhs)) return at;
            at = bare(tree, lhs);
        },
        else => return at,
    };
}

fn isNull(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "null");
}

/// How a function's result relates to a parameter at every `return` of a value: `result -
/// param >= least`, or, for `length`, `param.len - result >= least`.
const Relation = struct { param: u16, length: bool, least: i132 };

/// Function summaries, each read once; std's positions by declaration.
const Summaries = struct {
    map: std.AutoHashMapUnmanaged(Facts.Decl, []const Relation) = .empty,
    std_found: bool = false,
    std_positions: std.AutoHashMapUnmanaged(Facts.Decl, []const Relation) = .empty,
};

/// std's positions, its documented contracts: a `find` gives a position below the slice's length
/// (at most it, less the needle's, for a needle), and at least the start it is given.
const std_positions = [_]struct { name: []const u8, relations: []const Relation }{
    .{ .name = "mem.findScalar", .relations = &.{.{ .param = 1, .length = true, .least = 1 }} },
    .{ .name = "mem.findScalarLast", .relations = &.{.{ .param = 1, .length = true, .least = 1 }} },
    .{ .name = "mem.findAny", .relations = &.{.{ .param = 1, .length = true, .least = 1 }} },
    .{ .name = "mem.findLastAny", .relations = &.{.{ .param = 1, .length = true, .least = 1 }} },
    .{ .name = "mem.findNone", .relations = &.{.{ .param = 1, .length = true, .least = 1 }} },
    .{ .name = "mem.findLastNone", .relations = &.{.{ .param = 1, .length = true, .least = 1 }} },
    .{ .name = "mem.findScalarPos", .relations = &.{ .{ .param = 1, .length = true, .least = 1 }, .{ .param = 2, .length = false, .least = 0 } } },
    .{ .name = "mem.findAnyPos", .relations = &.{ .{ .param = 1, .length = true, .least = 1 }, .{ .param = 2, .length = false, .least = 0 } } },
    .{ .name = "mem.findNonePos", .relations = &.{ .{ .param = 1, .length = true, .least = 1 }, .{ .param = 2, .length = false, .least = 0 } } },
    .{ .name = "mem.find", .relations = &.{.{ .param = 1, .length = true, .least = 0 }} },
    .{ .name = "mem.findLast", .relations = &.{.{ .param = 1, .length = true, .least = 0 }} },
    .{ .name = "mem.findLastLinear", .relations = &.{.{ .param = 1, .length = true, .least = 0 }} },
    .{ .name = "mem.findPos", .relations = &.{ .{ .param = 1, .length = true, .least = 0 }, .{ .param = 2, .length = false, .least = 0 } } },
    .{ .name = "mem.findPosLinear", .relations = &.{ .{ .param = 1, .length = true, .least = 0 }, .{ .param = 2, .length = false, .least = 0 } } },
    .{ .name = "mem.findDiff", .relations = &.{ .{ .param = 1, .length = true, .least = 0 }, .{ .param = 2, .length = true, .least = 0 } } },
};

/// How `decl`'s result relates to its parameters: std's positions by declaration, a function of
/// the program's by what holds at each of its `return`s of a value.
fn summary(c: *Context, decl: Facts.Decl) Context.Error![]const Relation {
    const memo = try c.facts.memo(Summaries);
    if (!memo.std_found) {
        memo.std_found = true;
        for (std_positions) |known| for ((try Governed.declarations(c, "std", known.name)) orelse &.{}) |each| {
            try memo.std_positions.put(c.allocator, (try c.facts.origin(each)) orelse each, known.relations);
        };
    }
    const origin = (try c.facts.origin(decl)) orelse decl;
    if (memo.std_positions.get(origin)) |known| return known;
    if (memo.map.get(origin)) |known| return known;
    // A function that reaches itself relates to nothing while it is being read.
    try memo.map.put(c.allocator, origin, &.{});
    const input = c.project.inputs[origin.file.raw()];
    if (!input.selected or input.classification == .@"test") return &.{};
    const tree = &c.project.files[origin.file.raw()].tree;
    const model = &c.project.models[origin.file.raw()];
    const function = definitionOf(tree, model, model.declarations[origin.index].node) orelse return &.{};
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return &.{};
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var returns: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last or enclosing(tree, model, node) != function) continue;
        const value = unwrapped(tree, tree.nodeData(node).opt_node.unwrap() orelse continue);
        if (isNull(tree, value) or tree.nodeTag(value) == .error_value) continue;
        try returns.append(c.allocator, node);
    }
    var out: std.ArrayList(Relation) = .empty;
    if (returns.items.len > 0) {
        var it = proto.iterate(tree);
        var index: u16 = 0;
        while (it.next()) |param| : (index += 1) {
            const type_node = param.type_expr orelse continue;
            const name = param.name_token orelse continue;
            const use = paramUse(tree, model, function, name) orelse continue;
            const slice = if (tree.fullPtrType(type_node)) |ptr| ptr.size == .slice else false;
            const integer_param = (try named(c, origin.file, type_node, 64)) != null;
            if (!slice and !integer_param) continue;
            var most: ?i132 = null;
            for (returns.items) |ret| {
                const value = unwrapped(tree, tree.nodeData(ret).opt_node.unwrap().?);
                var difference: Linear = .{};
                const spread = if (slice)
                    difference.term(Linear.Term.of(tree, use, true, false)) and difference.put(tree, value, true)
                else
                    difference.put(tree, value, false) and difference.put(tree, use, true);
                if (!spread) {
                    most = -Interval.far;
                    break;
                }
                const found = try least(c, origin.file, difference, ret, 64, 0, true);
                most = if (most) |m| @min(m, found) else found;
            }
            const k = most orelse continue;
            if (k <= -Interval.far) continue;
            try out.append(c.allocator, .{ .param = index, .length = slice, .least = k });
        }
    }
    const found = try out.toOwnedSlice(c.allocator);
    try memo.map.put(c.allocator, origin, found);
    try keep(c, .{ .summaries = origin });
    return found;
}

/// A name in `function`'s body that reads the parameter named at `name`.
fn paramUse(tree: *const Ast, model: anytype, function: Ast.Node.Index, name: Ast.TokenIndex) ?Ast.Node.Index {
    var param: ?u32 = null;
    for (model.declarations, 0..) |decl, d| if (decl.kind == .parameter and decl.token == name) {
        param = @intCast(d);
    };
    const index = param orelse return null;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        if (refersTo(model, tree, node, index)) return node;
    }
    return null;
}

/// Whether a local only grows: every store into it adds a value never below zero, and
/// nothing takes its address or stores it otherwise.
fn grows(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!bool {
    const tree = &c.project.files[decl.file.raw()].tree;
    const model = &c.project.models[decl.file.raw()];
    const record = model.declarations[decl.index];
    const function = enclosing(tree, model, record.node) orelse return false;
    const memo = try c.facts.memo(Constants);
    const key = .{ decl, pointer };
    if (memo.grows.get(key)) |known| return known;
    try memo.grows.put(c.allocator, key, false);
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    const out = scan: for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        switch (tag) {
            .assign_add, .assign_add_sat => {
                const target, const given = tree.nodeData(node).node_and_node;
                if (!refersTo(model, tree, target, decl.index)) continue;
                if ((try bound(c, decl.file, given, pointer, 0)).least < 0) break :scan false;
            },
            .assign, .assign_sub, .assign_sub_sat, .assign_mul, .assign_mul_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap => {
                if (refersTo(model, tree, tree.nodeData(node).node_and_node[0], decl.index)) break :scan false;
            },
            .assign_destructure => for (tree.assignDestructure(node).ast.variables) |each| {
                if (refersTo(model, tree, each, decl.index)) break :scan false;
            },
            .address_of => if (refersTo(model, tree, bare(tree, tree.nodeData(node).node), decl.index)) break :scan false,
            else => {},
        }
    } else true;
    try memo.grows.put(c.allocator, key, out);
    try keep(c, .{ .grows = key });
    return out;
}

/// The least value a sum can have by its terms' own ranges, where it has at most two.
fn evaluated(c: *Context, file: Project.FileId, value: Linear, pointer: u16, depth: u8) Context.Error!i132 {
    if (value.len > 2) return -Interval.far;
    var out: i132 = value.constant;
    for (value.terms[0..value.len]) |each| {
        const range: Interval = if (each.length)
            if (each.node) |memory| (if (try fixedLength(c, file, memory)) |n| Interval.exactly(n) else Interval{ .least = 0, .most = length(pointer) }) else .{ .least = 0, .most = length(pointer) }
        else if (each.node) |node|
            try bound(c, file, node, pointer, depth + 1)
        else
            return -Interval.far;
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
        const decl: Facts.Decl = .{ .file = file, .index = ref.declaration orelse continue };
        // A variable's quotient may be replaced before it is read.
        if (!constantDecl(c, decl)) continue;
        const init = (try untyped(c, decl)) orelse continue;
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
    return std.mem.eql(u8, spelled(tree, a), spelled(tree, b));
}

/// How an expression is spelled, parentheses and the conversions that keep a value aside.
fn spelled(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    return std.mem.trim(u8, tree.getNodeSource(bare(tree, node)), " ");
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
    if (!room.putLength(tree, memory, false) or !room.put(tree, index, true)) return false;
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
