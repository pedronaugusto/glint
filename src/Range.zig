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
const Model = @import("Model.zig");
const Contract = @import("AegisContract.zig");
const Governed = @import("Governed.zig");
const Metrics = @import("Metrics.zig");
const Ast = std.zig.Ast;

/// An integer type: its width, and whether it is signed. A C type's width can differ between
/// targets at one pointer width (`c_long` is 32 bits on Windows, 64 elsewhere on 64-bit
/// ones): `bits` is its narrowest there and `wide` its widest. `c_char`'s sign differs too
/// (`either`): it may be negative, and may reach 255.
pub const Int = struct {
    bits: u16,
    signed: bool,
    wide: ?u16 = null,
    either: bool = false,

    /// The greatest magnitude the type holds on every target: what a conversion into it or
    /// arithmetic in it must stay within.
    fn room(self: Int) u128 {
        return filled(if (self.signed) self.bits -| 1 else self.bits);
    }

    /// The greatest magnitude a value of the type can have on some target.
    fn reach(self: Int) u128 {
        const bits = self.wide orelse self.bits;
        return filled(if (self.signed and !self.either) bits -| 1 else bits);
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
        const wide: ?u16 = if (x.wide == null and y.wide == null) null else @max(x.wide orelse x.bits, y.wide orelse y.bits);
        const either = x.either or y.either;
        if (x.signed == y.signed) return .{ .int = .{ .bits = @max(x.bits, y.bits), .signed = x.signed, .wide = wide, .either = either } };
        const signed = if (x.signed) x else y;
        const unsigned = if (x.signed) y else x;
        return .{ .int = .{ .bits = @max(signed.bits, unsigned.bits + 1), .signed = true, .wide = if (wide) |w| @max(w, unsigned.bits + 1) else null, .either = either } };
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
        // A midpoint, `a + (b - a) / k`, is at most `b`: it fits where `b` does (the
        // difference's own underflow is judged where it is taken).
        if (tag == .add and midpoint(tree, lhs, rhs)) continue;
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
        if (from.signed and (!into.signed or into.either) and !try nonnegative(c, file, operand, pointer)) return false;
        const magnitude = (try bound(c, file, operand, pointer, 0)) orelse return false;
        if (magnitude > into.room()) return false;
    }
    return true;
}

/// Whether a value is shown narrower than the integer type `declared` (in `declared_file`)
/// gives it, at every pointer width: held to 16 bits (a byte, two bytes put together), or put
/// below the type's greatest by a comparison with a constant where it is read (a count checked
/// below its limit). A wider source is no bound: a `u32` a peer sent fills a `u64` field with a
/// peer's number. A `bool` holds no number; a value of the type's whole range, or a type the
/// reading does not know, shows none.
pub fn shown(c: *Context, file: Project.FileId, value: Ast.Node.Index, declared_file: Project.FileId, declared: Ast.Node.Index) Context.Error!bool {
    const types = &c.project.files[declared_file.raw()].tree;
    if (types.nodeTag(declared) == .identifier and std.mem.eql(u8, types.tokenSlice(types.nodeMainToken(declared)), "bool")) return true;
    for (widths(c)) |pointer| {
        const into = (try named(c, declared_file, declared, pointer)) orelse return false;
        const most = (try bound(c, file, value, pointer, 0)) orelse return false;
        if (most >= into.reach()) return false;
        if (most <= std.math.maxInt(u16)) continue;
        if (!try nonnegative(c, file, value, pointer)) return false;
        const compared = (try upperByConstant(c, file, unwrapped(c, file, value), value, pointer)) orelse return false;
        if (compared >= into.reach()) return false;
    }
    return true;
}

/// What the comparisons holding at `at` put `node` at most where they compare it with a
/// constant the program chose: a literal, a constant naming one, or `std.math.maxInt` of a
/// type. A comparison with another value (another number a peer sent) shows no limit of the
/// program's.
fn upperByConstant(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, pointer: u16) Context.Error!?u128 {
    const tree = &c.project.files[file.raw()].tree;
    if (tree.nodeTag(node) != .identifier and tree.nodeTag(node) != .field_access) return null;
    var out: ?u128 = null;
    for (try facts(c, file, at)) |fact| {
        const base, const k = offset(tree, fact.small);
        if (!same(tree, base, node)) continue;
        const large = bare(tree, fact.large);
        const most: u128 = if (try valueOf(c, file, large, 0)) |value| value else most: {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, large) orelse continue;
            const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |d| d,
                else => continue,
            };
            break :most (try extreme(c, file, decl, call, pointer)) orelse continue;
        };
        out = narrower(out, (if (fact.strict) most -| 1 else most) -| k);
    }
    return out;
}

/// The value a conversion or grouping holds (`@as(u64, n)`, `(n)`), whose comparisons are its.
fn unwrapped(c: *Context, file: Project.FileId, value: Ast.Node.Index) Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    var at = value;
    while (true) {
        switch (tree.nodeTag(at)) {
            .grouped_expression => at = tree.nodeData(at).node_and_token[0],
            .builtin_call_two, .builtin_call_two_comma => {
                const name = tree.tokenSlice(tree.nodeMainToken(at));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, at, &buffer);
                if (std.mem.eql(u8, name, "@as") and args.len == 2) at = args[1] else if (std.mem.eql(u8, name, "@intCast") and args.len == 1) at = args[0] else return at;
            },
            else => return at,
        }
    }
}

/// Whether a type expression names an integer type.
pub fn integral(c: *Context, file: Project.FileId, type_node: Ast.Node.Index) Context.Error!bool {
    return (try named(c, file, type_node, widths(c)[0])) != null;
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
        .int => |int| int.reach(),
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
/// holding where it is read puts it at a literal or above (`if (x < 0) return`, `if (x > 0)`),
/// or it is made of what cannot be: a literal, a magnitude (`@abs`), a conversion of such a
/// value, a sum, product or quotient by a positive literal of such values, or a local
/// initialized with one that nothing assigns before the read.
fn nonnegative(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!bool {
    return nonnegativeAt(c, file, node, node, pointer, 0);
}

/// What a nonnegativity reading takes as given: a local whose every value is being shown at
/// zero or above (so its own reads in them are, by induction), and an assignment left out,
/// the one a negation being judged makes of the local (`x = -x`), whose value no read before
/// it sees.
const Assumed = struct { local: ?u32 = null, skip: ?Ast.Node.Index = null };

fn nonnegativeAt(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!bool {
    return nonnegativeIn(c, file, node, at, pointer, depth, .{});
}

fn nonnegativeIn(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, pointer: u16, depth: u8, assumed: Assumed) Context.Error!bool {
    if (depth > depth_limit) return false;
    const next = depth + 1;
    switch (try typeOf(c, file, node, pointer, 0)) {
        .int => |int| if (!int.signed) return true,
        else => {},
    }
    const tree = &c.project.files[file.raw()].tree;
    for (try facts(c, file, at)) |fact| {
        if (literal(tree, fact.small) != null and same(tree, fact.large, node)) return true;
    }
    // What an operation makes at zero or above: `@max(x, 0)`, `@mod(x, k)` by a positive `k`
    // (its sign is the divisor's), `x & mask` by a literal mask.
    const value = bare(tree, node);
    if (literal(tree, value) != null) return true;
    switch (tree.nodeTag(value)) {
        .bit_and => {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            return literal(tree, lhs) != null or literal(tree, rhs) != null;
        },
        .add, .mul, .add_sat, .mul_sat => {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            return try nonnegativeIn(c, file, lhs, at, pointer, next, assumed) and try nonnegativeIn(c, file, rhs, at, pointer, next, assumed);
        },
        .div => {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            return (literal(tree, rhs) orelse 0) > 0 and try nonnegativeIn(c, file, lhs, at, pointer, next, assumed);
        },
        .builtin_call_two, .builtin_call_two_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(value));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, value, &buffer);
            if (std.mem.eql(u8, name, "@abs")) return true;
            if (args.len == 1 and std.mem.eql(u8, name, "@intCast")) return nonnegativeIn(c, file, args[0], at, pointer, next, assumed);
            if (args.len != 2) return false;
            if (std.mem.eql(u8, name, "@as")) return nonnegativeIn(c, file, args[1], at, pointer, next, assumed);
            if (std.mem.eql(u8, name, "@max")) return literal(tree, args[0]) != null or literal(tree, args[1]) != null;
            if (std.mem.eql(u8, name, "@mod")) return (literal(tree, args[1]) orelse 0) > 0;
            if (std.mem.eql(u8, name, "@rem")) return (literal(tree, args[1]) orelse 0) > 0 and try nonnegativeIn(c, file, args[0], at, pointer, next, assumed);
            if (std.mem.eql(u8, name, "@divTrunc") or std.mem.eql(u8, name, "@divFloor")) return (literal(tree, args[1]) orelse 0) > 0 and try nonnegativeIn(c, file, args[0], at, pointer, next, assumed);
        },
        .identifier => {
            const model = &c.project.models[file.raw()];
            const d = (model.reference(value) orelse return false).declaration orelse return false;
            if (assumed.local == d) return true;
            const record = model.declarations[d];
            if (record.kind != .variable) return false;
            const variable = tree.fullVarDecl(record.node) orelse return false;
            const init = variable.ast.init_node.unwrap() orelse return false;
            if (tree.tokenTag(variable.ast.mut_token) == .keyword_const or try kept(c, file, value, record.node, at)) return nonnegativeIn(c, file, init, init, pointer, next, assumed);
            // A variable every value of which is at zero or above: its initializer and what
            // each assignment gives it, its own reads in them taken as such.
            if (assumed.local != null) return false;
            const inductive: Assumed = .{ .local = d, .skip = assumed.skip };
            if (!try nonnegativeIn(c, file, init, init, pointer, next, inductive)) return false;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                const assignment: Ast.Node.Index = @fromBackingInt(@intCast(i));
                switch (tag) {
                    .assign, .assign_add, .assign_mul, .assign_add_sat, .assign_mul_sat => {},
                    .assign_sub, .assign_sub_wrap, .assign_add_wrap, .assign_mul_wrap, .assign_sub_sat, .assign_div, .assign_mod, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {
                        const target = tree.nodeData(assignment).node_and_node[0];
                        if (tree.nodeTag(target) == .identifier) if (model.reference(target)) |r| if (r.declaration == d) return false;
                        continue;
                    },
                    else => continue,
                }
                const target, const given = tree.nodeData(assignment).node_and_node;
                if (tree.nodeTag(target) != .identifier) continue;
                const ref = model.reference(target) orelse continue;
                if (ref.declaration != d) continue;
                if (assumed.skip == assignment) continue;
                if (!try nonnegativeIn(c, file, given, given, pointer, next, inductive)) return false;
            }
            // Any other write is none the induction reads: its address handed on lets a callee
            // write it, and a destructuring or an `asm` output writes it directly.
            if (try written(c, file, d)) return false;
            return true;
        },
        else => {},
    }
    return false;
}

/// Whether a local is written other than by an assignment to its name: its address taken, a
/// destructuring assignment naming it, or an `asm` output.
fn written(c: *Context, file: Project.FileId, d: u32) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .address_of => {
                const operand = tree.nodeData(node).node;
                if (tree.nodeTag(operand) == .identifier) if (model.reference(operand)) |r| if (r.declaration == d) return true;
            },
            .assign_destructure => for (tree.assignDestructure(node).ast.variables) |variable| {
                if (tree.nodeTag(variable) == .identifier) if (model.reference(variable)) |r| if (r.declaration == d) return true;
            },
            .asm_output => if (outputNames(tree, node, model.declarations[d].name)) return true,
            else => {},
        }
    }
    return false;
}

/// Whether an `asm` output writes the variable `name` (`[out] "=r" (name)`).
fn outputNames(tree: *const Ast, output: Ast.Node.Index, name: []const u8) bool {
    const rparen = tree.nodeData(output).opt_node_and_token[1];
    return tree.tokenTag(rparen - 1) == .identifier and std.mem.eql(u8, tree.tokenSlice(rparen - 1), name);
}

/// Whether `a + half` is `a + (b - a) / k` with a literal `k` of at least one.
fn midpoint(tree: *const Ast, a: Ast.Node.Index, half: Ast.Node.Index) bool {
    const q = bare(tree, half);
    if (tree.nodeTag(q) != .div) return false;
    const dividend, const divisor = tree.nodeData(q).node_and_node;
    if ((literal(tree, divisor) orelse 0) < 1) return false;
    const d = bare(tree, dividend);
    if (tree.nodeTag(d) != .sub) return false;
    return same(tree, tree.nodeData(d).node_and_node[1], a);
}

/// Whether `node` is arithmetic on a pointer (`ptr + i`): an address, which no checked
/// overflow stops.
pub fn addresses(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    return pointerValue(c, file, tree.nodeData(node).node_and_node[0], 0);
}

/// Whether pointer arithmetic stays within the memory its pointer came from, and so does what
/// is read through it: `x.ptr + o` with `o` below the length of `x` leaves `x.len - o` bytes, at
/// least one, so a read of its first element (`(x.ptr + o)[0]`, `[0..1]`) is within. Any other
/// read, or the moved pointer kept or given on, reaches past what the comparison shows. Only a
/// pointer moved forward is: `x.ptr - o` reaches before the memory whatever `o` is below.
pub fn movedWithin(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    if (tree.nodeTag(node) != .add) return false;
    const base, const moved = tree.nodeData(node).node_and_node;
    const at = bare(tree, base);
    if (tree.nodeTag(at) != .field_access) return false;
    const memory, const name = tree.nodeData(at).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(name), "ptr")) return false;
    if (!firstRead(c, file, node)) return false;
    return within(c, file, moved, memory, false);
}

/// Whether a moved pointer is read only at its first element, where it is computed.
fn firstRead(c: *Context, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &c.project.files[file.raw()].tree;
    const parents = c.project.models[file.raw()].node_parents;
    var at = node;
    var parent = parents[@backingInt(at)] orelse return false; // safe: a node index indexes its own tree's parent table.
    while (tree.nodeTag(parent) == .grouped_expression) {
        at = parent;
        parent = parents[@backingInt(at)] orelse return false; // safe: a node index indexes its own tree's parent table.
    }
    if (tree.nodeTag(parent) == .array_access) {
        const reached, const index = tree.nodeData(parent).node_and_node;
        return reached == at and literal(tree, index) == 0;
    }
    const slice = tree.fullSlice(parent) orelse return false;
    if (slice.ast.sliced != at or literal(tree, slice.ast.start) != 0) return false;
    const end = slice.ast.end.unwrap() orelse return false;
    return (literal(tree, end) orelse return false) <= 1;
}

/// Whether a value is a pointer: one it resolves to, its address as an integer
/// (`@intFromPtr(p)`), an address moved from one (`p + i`, `p - i`), or a constant naming
/// either (`const m = out.ptr + o_lit;`).
fn pointerValue(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > 4) return false;
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, node);
    switch (try c.facts.resolve(file, at)) {
        .pointer => return true,
        else => {},
    }
    switch (tree.nodeTag(at)) {
        .add, .sub, .add_wrap, .sub_wrap => return pointerValue(c, file, tree.nodeData(at).node_and_node[0], depth + 1),
        .identifier => {
            const local = constantOf(c, file, at) orelse return false;
            return pointerValue(c, file, local.ast.init_node.unwrap() orelse return false, depth + 1);
        },
        .builtin_call_two, .builtin_call_two_comma => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), "@intFromPtr"),
        else => return false,
    }
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
            if (prong(c, .{ .file = file, .index = d })) |range| return range.most;
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
            // An unsigned difference that does not underflow is at most what it takes from, less
            // a constant it takes (an underflow stops the program: A010's to judge).
            if (!signed) return ((try bound(c, file, lhs, pointer, next)) orelse return null) -| (literal(tree, rhs) orelse 0);
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
        return int.reach();
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
    // A count of bits: at most its operand's width, at most 65535.
    if (is(name, &.{ "@ctz", "@clz", "@popCount" })) {
        if (args.len == 1) switch (try typeOf(c, file, args[0], pointer, depth)) {
            .int => |int| return int.wide orelse int.bits,
            else => {},
        };
        return std.math.maxInt(u16);
    }
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
    /// The structs whose bytes something may write that no store shows: a value of one viewed as
    /// bytes (`std.mem.asBytes`) or reinterpreted (`@ptrCast`, `@bitCast`, `@memcpy`), a pointer
    /// to one handed to a function outside the program (a reader, an `extern`), whose writes are
    /// not read, or one stored into through a name not known as it compiles (`@field(x, name)`).
    exposed: std.AutoHashMapUnmanaged(struct { Project.FileId, u32 }, void) = .empty,
    /// A store's file and node: an assignment (or one that changes the field in place, or takes
    /// its address), or a struct literal's field value.
    const Site = struct { file: Project.FileId, node: Ast.Node.Index, kind: enum { assign, changes, literal, named } };
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
            try expose(c, memo, file, node);
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
            // `@field(x, "name") = v` stores into the field it names.
            if (fieldBuiltin(tree, target)) |named_field| {
                if (named_field.name) |name| try add(c, memo, name, .{ .file = file, .node = node, .kind = if (kind == .assign) .named else .changes });
                continue;
            }
            if (tree.nodeTag(target) != .field_access) continue;
            try add(c, memo, tree.tokenSlice(tree.nodeData(target).node_and_token[1]), .{ .file = file, .node = node, .kind = kind });
        }
    }
    return memo;
}

/// `@field(holder, name)`: its holder, and its name where a string literal spells it.
fn fieldBuiltin(tree: *const Ast, node: Ast.Node.Index) ?struct { holder: Ast.Node.Index, name: ?[]const u8 } {
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return null,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) return null;
    const holder, const name_node = tree.nodeData(node).opt_node_and_opt_node;
    const name = name_node.unwrap() orelse return null;
    const spelled: ?[]const u8 = if (tree.nodeTag(name) == .string_literal) blk: {
        const text = tree.tokenSlice(tree.nodeMainToken(name));
        break :blk if (text.len >= 2) text[1 .. text.len - 1] else null;
    } else null;
    return .{ .holder = holder.unwrap() orelse return null, .name = spelled };
}

/// Marks the structs a node lets something write without a store: see `Stores.exposed`.
fn expose(c: *Context, memo: *Stores, file: Project.FileId, node: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (std.mem.eql(u8, name, "@field")) {
                const named_field = fieldBuiltin(tree, node) orelse return;
                if (named_field.name == null) try exposeValue(c, memo, file, named_field.holder);
                return;
            }
            for ([_][]const u8{ "@ptrCast", "@bitCast", "@memcpy", "@memset", "@memmove" }) |reinterpret| if (std.mem.eql(u8, name, reinterpret)) {
                for (args) |arg| try exposeValue(c, memo, file, arg);
                // What a reinterpretation makes is its destination's: bytes viewed as a struct.
                if (try destined(c, file, node)) |into| switch (into) {
                    .named => |type_node| try exposeType(c, memo, try c.facts.resolve(type_node.file, type_node.node)),
                    .assigned => |lhs| try exposeValue(c, memo, file, lhs),
                    .field => |decl| try exposeType(c, memo, try c.facts.declaration(decl)),
                    else => {},
                };
                return;
            };
        },
        else => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node) orelse return;
            const callee = try c.facts.resolve(file, call.ast.fn_expr);
            const own = switch (callee) {
                .function => |decl| c.project.inputs[decl.file.raw()].selected,
                else => false,
            };
            // std's byte views write through the bytes they give.
            const viewed = if (tree.nodeTag(call.ast.fn_expr) == .field_access) blk: {
                const method = tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]);
                break :blk std.mem.eql(u8, method, "asBytes") or std.mem.eql(u8, method, "sliceAsBytes") or std.mem.eql(u8, method, "bytesAsValue") or std.mem.eql(u8, method, "bytesAsSlice");
            } else false;
            if (own and !viewed) return;
            for (call.ast.params) |arg| {
                // A struct handed over by value is a copy: what is written is not it.
                if (!viewed and tree.nodeTag(arg) != .address_of) {
                    var value = try c.facts.resolve(file, arg);
                    while (value == .optional) value = value.optional.*;
                    if (value != .pointer) continue;
                }
                try exposeValue(c, memo, file, arg);
            }
            if (viewed) if (try destined(c, file, node)) |into| switch (into) {
                .named => |type_node| try exposeType(c, memo, try c.facts.resolve(type_node.file, type_node.node)),
                else => {},
            };
        },
    }
}

fn exposeValue(c: *Context, memo: *Stores, file: Project.FileId, node: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    var at = node;
    while (true) at = switch (tree.nodeTag(at)) {
        .address_of => tree.nodeData(at).node,
        .grouped_expression => tree.nodeData(at).node_and_token[0],
        else => break,
    };
    try exposeType(c, memo, try c.facts.resolve(file, at));
}

/// Marks the struct a value is, points to or holds an array of.
fn exposeType(c: *Context, memo: *Stores, value: Facts.Value) Context.Error!void {
    var inner_value = value;
    while (true) inner_value = switch (inner_value) {
        .pointer, .optional, .array, .error_union => |inner| inner.*,
        else => break,
    };
    const k = switch (inner_value) {
        .instance, .container => |k| k,
        .alternatives => |each| {
            for (each) |one| try exposeType(c, memo, one);
            return;
        },
        else => return,
    };
    try memo.exposed.put(c.allocator, .{ k.file, k.scope }, {});
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
    if (found.exposed.contains(.{ decl.file, record.scope })) return null;
    var out: ?u128 = 0;
    if (field_decl.ast.value_expr.unwrap()) |default| if (!empty(tree, default)) {
        out = try bound(c, decl.file, default, pointer, depth);
    };
    const sites = found.sites.get(record.name) orelse std.ArrayList(Stores.Site).empty;
    for (sites.items) |site| {
        if (out == null) break;
        const site_tree = &c.project.files[site.file.raw()].tree;
        switch (site.kind) {
            // `@field(x, "name") = v`: a store to the field of x's struct it names.
            .named => {
                const target = site_tree.nodeData(site.node).node_and_node[0];
                const field_holder = (fieldBuiltin(site_tree, target) orelse continue).holder;
                var holder_value = try c.facts.resolve(site.file, field_holder);
                while (true) holder_value = switch (holder_value) {
                    .pointer, .optional => |inner| inner.*,
                    else => break,
                };
                const container = switch (holder_value) {
                    .instance, .container => |k| k,
                    // A holder whose type is not known may be this one.
                    else => {
                        out = null;
                        continue;
                    },
                };
                if (!container.file.eql(decl.file) or container.scope != record.scope) continue;
                const value = site_tree.nodeData(site.node).node_and_node[1];
                if (!empty(site_tree, value)) out = wider(out, try bound(c, site.file, value, pointer, depth));
            },
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
                .int => |int| .{ .int = .{ .bits = int.bits, .signed = false, .wide = int.wide } },
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
            if (decl) |d| if (try element(c, d, pointer)) |typed| return typed;
        },
        else => {},
    }
    return integer(try c.facts.resolve(file, node), pointer);
}

/// The type of a `for` capture taking an element of memory (`for (bytes) |b|` over a
/// `[]const u8` is a `u8`), or of a range's index (`usize`); null for anything else.
fn element(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!?Typed {
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    if (record.kind != .capture) return null;
    const loop = tree.fullFor(record.node) orelse return null;
    if (tree.tokenTag(record.token - 1) == .asterisk) return null;
    var token = loop.payload_token;
    var index: usize = 0;
    while (tree.tokenTag(token) != .pipe) : (token += 1) {
        if (tree.tokenTag(token) != .identifier) continue;
        if (token == record.token) break;
        index += 1;
    } else return null;
    if (index >= loop.ast.inputs.len) return null;
    const input = loop.ast.inputs[index];
    if (tree.nodeTag(input) == .for_range) return .{ .int = .{ .bits = pointer, .signed = false } };
    var value = try c.facts.resolve(decl.file, input);
    while (true) switch (value) {
        .pointer, .array => |inner| value = inner.*,
        else => break,
    };
    return switch (integer(value, pointer)) {
        .int => |int| .{ .int = int },
        else => null,
    };
}

/// The least and greatest value an inline prong's capture takes: its prong's items, each a
/// literal or a range of literals (`inline 1...7 => |period|`). Null for any other capture.
const Reach = struct { least: u128, most: u128 };
fn prong(c: *Context, decl: Facts.Decl) ?Reach {
    const model = &c.project.models[decl.file.raw()];
    const tree = &c.project.files[decl.file.raw()].tree;
    const record = model.declarations[decl.index];
    if (record.kind != .capture) return null;
    const case = tree.fullSwitchCase(record.node) orelse return null;
    if (case.inline_token == null or case.payload_token != record.token or case.ast.values.len == 0) return null;
    var out: Reach = .{ .least = std.math.maxInt(u128), .most = 0 };
    for (case.ast.values) |item| {
        const low, const high = if (tree.nodeTag(item) == .switch_range) tree.nodeData(item).node_and_node else .{ item, item };
        const a = literal(tree, low) orelse return null;
        const b = literal(tree, high) orelse return null;
        out = .{ .least = @min(out.least, a), .most = @max(out.most, b) };
    }
    return out;
}

/// Whether a divisor cannot be zero: a literal other than zero, `@max(k, x)` with `k` at least
/// one, an inline prong's capture whose items are all above zero, a constant naming one, or a
/// value a comparison holding where it is read puts above zero (`if (n == 0) return`, `if (x >=
/// 1)`, or above another value that cannot be negative: the `else` of `if (a >= len)`).
pub fn nonzero(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return nonzeroAt(c, file, node, node, 0);
}

fn nonzeroAt(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > depth_limit) return false;
    const tree = &c.project.files[file.raw()].tree;
    const value = bare(tree, node);
    if (literal(tree, value)) |k| return k != 0;
    switch (tree.nodeTag(value)) {
        .builtin_call_two, .builtin_call_two_comma => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@max")) {
            var buffer: [2]Ast.Node.Index = undefined;
            for (Facts.builtinArgs(tree, value, &buffer)) |arg| if ((literal(tree, arg) orelse 0) >= 1) return true;
        },
        .identifier => {
            const model = &c.project.models[file.raw()];
            if (model.reference(value)) |ref| if (ref.declaration) |d| {
                if (prong(c, .{ .file = file, .index = d })) |range| if (range.least >= 1) return true;
            };
            if (constantOf(c, file, value)) |local| if (local.ast.init_node.unwrap()) |init| {
                if (try nonzeroAt(c, file, init, at, depth + 1)) return true;
            };
        },
        else => {},
    }
    for (try gather(c, file, at)) |fact| {
        if (fact.read) continue;
        // Other than zero, and not negative: no -1 that overflows a signed minimum.
        if (fact.differs) {
            if (!(same(tree, fact.small, value) and literal(tree, fact.large) == 0) and !(same(tree, fact.large, value) and literal(tree, fact.small) == 0)) continue;
            for (widths(c)) |pointer| {
                if (!try nonnegative(c, file, value, pointer)) break;
            } else return true;
            continue;
        }
        if (!same(tree, fact.large, value)) continue;
        if (literal(tree, fact.small)) |k| {
            if (k >= 1 or fact.strict) return true;
            continue;
        }
        if (!fact.strict) continue;
        for (widths(c)) |pointer| {
            if (!try nonnegative(c, file, fact.small, pointer)) break;
        } else return true;
    }
    return false;
}

/// Whether a value is of an unsigned integer type at every pointer width.
fn unsignedAll(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    for (widths(c)) |pointer| switch (try typeOf(c, file, node, pointer, 0)) {
        .int => |int| if (int.signed) return false,
        else => return false,
    };
    return true;
}

/// Whether negating `node` cannot overflow: a signed value that is not negative is no minimum.
pub fn negates(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    // `x = -x` outside a loop: the value it makes is no value the negation reads.
    var assumed: Assumed = .{};
    if (model.node_parents[@backingInt(node)]) |negation| if (model.node_parents[@backingInt(negation)]) |parent| {
        if (tree.nodeTag(parent) == .assign and same(tree, tree.nodeData(parent).node_and_node[0], node) and !looped(tree, model, parent)) assumed.skip = parent;
    };
    for (widths(c)) |pointer| {
        if (try nonnegativeIn(c, file, node, node, pointer, 0, assumed)) continue;
        // A value widened to a type of more bits (`-@as(i64, offset)` of an `i32`) is no
        // minimum of the wider type.
        if (!try widened(c, file, node, pointer)) return false;
    }
    return true;
}

/// Whether a value is `@as(T, x)` with `x` of an integer type narrower than `T`.
fn widened(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    switch (tree.nodeTag(at)) {
        .builtin_call_two, .builtin_call_two_comma => {},
        else => return false,
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), "@as")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, at, &buffer);
    if (args.len != 2) return false;
    const wide = (try named(c, file, args[0], pointer)) orelse return false;
    const narrow = switch (try typeOf(c, file, args[1], pointer, 0)) {
        .int => |int| int,
        else => return false,
    };
    return (narrow.wide orelse narrow.bits) < wide.bits;
}

/// Whether a node is inside a loop's body, within its function.
fn looped(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) { // safe: a node index indexes its own tree's parent table.
        switch (tree.nodeTag(parent)) {
            .while_simple, .while_cont, .@"while", .for_simple, .@"for" => return true,
            .fn_decl => return false,
            else => {},
        }
    }
    return false;
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
        .primitive => |name| return (name.len >= 2 and (name[0] == 'f' and std.ascii.isDigit(name[1]))) or std.mem.eql(u8, name, "comptime_float"),
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

/// A C integer type across the targets of one pointer width, as Zig's C ABI gives them:
/// `char` 8 bits of either sign, `short` 16, `int` 16 on 16-bit targets (AVR, MSP430) and 32
/// elsewhere, `long` 32 on Windows and on 16- and 32-bit targets and the pointer's width
/// elsewhere, `long long` 64.
fn cType(name: []const u8, pointer: u16) Typed {
    const unsigned = name.len > 1 and name[0] == 'u';
    const base = if (unsigned) name[1..] else name;
    if (std.mem.eql(u8, name, "char")) return .{ .int = .{ .bits = 8, .signed = true, .either = true } };
    if (std.mem.eql(u8, base, "short")) return .{ .int = .{ .bits = 16, .signed = !unsigned } };
    if (std.mem.eql(u8, base, "int")) return .{ .int = .{ .bits = if (pointer == 16) 16 else 32, .signed = !unsigned } };
    if (std.mem.eql(u8, base, "long")) return .{ .int = .{ .bits = 32, .signed = !unsigned, .wide = @max(pointer, 32) } };
    if (std.mem.eql(u8, base, "longlong")) return .{ .int = .{ .bits = 64, .signed = !unsigned } };
    return .unknown;
}

/// The integer type a resolved value is, seen through an optional or an error union.
fn integer(value: Facts.Value, pointer: u16) Typed {
    switch (value) {
        .optional, .error_union => |inner| return integer(inner.*, pointer),
        .primitive => |name| {
            if (std.mem.eql(u8, name, "comptime_int")) return .literal;
            if (std.mem.eql(u8, name, "usize")) return .{ .int = .{ .bits = pointer, .signed = false } };
            if (std.mem.eql(u8, name, "isize")) return .{ .int = .{ .bits = pointer, .signed = true } };
            if (std.mem.startsWith(u8, name, "c_")) return cType(name[2..], pointer);
            if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return .unknown;
            const bits = std.fmt.parseUnsigned(u16, name[1..], 10) catch return .unknown;
            return .{ .int = .{ .bits = bits, .signed = name[0] == 'i' } };
        },
        else => return .unknown,
    }
}

/// Where a conversion's result is read into: a type expression naming its type (what `@as`
/// names, a typed constant or variable it initializes, the parameter it is given to, the
/// function's result it returns), what it is assigned to, a struct literal's field, or the
/// backing integer of a `@fromBackingInt` or `@enumFromInt` it is given to.
const Destination = union(enum) {
    named: struct { file: Project.FileId, node: Ast.Node.Index },
    assigned: Ast.Node.Index,
    field: Facts.Decl,
    backing: Ast.Node.Index,
    /// A shift's amount, whose type is the log of the shifted value's width.
    shifted: Ast.Node.Index,
};

fn destined(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Destination {
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
                const name = tree.tokenSlice(tree.nodeMainToken(parent));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, parent, &buffer);
                if (std.mem.eql(u8, name, "@fromBackingInt") or std.mem.eql(u8, name, "@enumFromInt")) return if (args.len == 1) .{ .backing = parent } else null;
                if (!std.mem.eql(u8, name, "@as")) return null;
                if (args.len != 2 or args[1] != at) return null;
                return .{ .named = .{ .file = file, .node = args[0] } };
            },
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_bit_and, .assign_bit_or, .assign_bit_xor => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                return .{ .assigned = lhs };
            },
            .shl, .shr, .assign_shl, .assign_shr => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                return .{ .shifted = lhs };
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
                var call_buffer: [1]Ast.Node.Index = undefined;
                if (tree.fullCall(&call_buffer, parent)) |call| return argument(c, file, call, at);
                var init_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&init_buffer, parent)) |_| return .{ .field = (try field(c, file, parent, at)) orelse return null };
                return null;
            },
        }
    }
    return null;
}

/// The integer type a conversion's result is read into.
fn destination(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    return switch ((try destined(c, file, node)) orelse return null) {
        .named => |type_node| try named(c, type_node.file, type_node.node, pointer),
        .assigned => |lhs| switch (try typeOf(c, file, lhs, pointer, 0)) {
            .int => |int| int,
            else => null,
        },
        .field => |decl| switch (integer(try c.facts.declaration(decl), pointer)) {
            .int => |int| int,
            else => null,
        },
        .backing => |call| if (try backed(c, file, call, pointer)) |backing| backing.tag else null,
        .shifted => |value| switch (try typeOf(c, file, value, pointer, 0)) {
            .int => |int| .{ .bits = std.math.log2_int_ceil(u16, @max(int.bits, 1)), .signed = false },
            else => null,
        },
    };
}

/// What a `@fromBackingInt` or `@enumFromInt` makes, read from the declaration of the type
/// its result is read into: the backing integer, and the greatest value below which each is a
/// value of the type. A packed struct's or a non-exhaustive enum's backing integers are each
/// one of its values; an exhaustive enum's are the tags it names.
const Backing = struct {
    tag: Int,
    filled: u128,
};

fn backed(c: *Context, file: Project.FileId, call: Ast.Node.Index, pointer: u16) Context.Error!?Backing {
    var made = switch ((try destined(c, file, call)) orelse return null) {
        .named => |type_node| try c.facts.resolve(type_node.file, type_node.node),
        .assigned => |lhs| try c.facts.resolve(file, lhs),
        .field => |decl| try c.facts.declaration(decl),
        .backing, .shifted => return null,
    };
    while (made == .optional) made = made.optional.*;
    const container = switch (made) {
        .container, .instance => |k| k,
        else => return null,
    };
    const tree = &c.project.files[container.file.raw()].tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const declared = tree.fullContainerDecl(&buffer, c.project.models[container.file.raw()].scopes[container.scope].node) orelse return null;
    const kind = tree.tokenTag(declared.ast.main_token);
    const arg = declared.ast.arg.unwrap();
    if (kind == .keyword_struct or kind == .keyword_union) {
        // A packed type's backing integer is its bits, each pattern one of its values.
        const layout = declared.layout_token orelse return null;
        if (tree.tokenTag(layout) != .keyword_packed) return null;
        const tag = (try named(c, container.file, arg orelse return null, pointer)) orelse return null;
        return .{ .tag = tag, .filled = tag.room() };
    }
    if (kind != .keyword_enum) return null;
    var values: std.ArrayList(u64) = .empty;
    defer values.deinit(c.allocator);
    var open = false;
    var next: u64 = 0;
    for (declared.ast.members) |member| {
        const each = tree.fullContainerField(member) orelse continue;
        if (std.mem.eql(u8, tree.tokenSlice(each.ast.main_token), "_")) {
            open = true;
            continue;
        }
        if (each.ast.value_expr.unwrap()) |value| next = literal(tree, value) orelse return null;
        try values.append(c.allocator, next);
        next +%= 1;
    }
    const tag: Int = if (arg) |type_node| (try named(c, container.file, type_node, pointer)) orelse return null else .{ .bits = if (values.items.len < 2) 0 else std.math.log2_int_ceil(u64, values.items.len), .signed = false };
    if (open) return .{ .tag = tag, .filled = tag.room() };
    if (tag.signed) return null;
    std.mem.sortUnstable(u64, values.items, {}, std.sort.asc(u64));
    // The values from zero each tag names, without a gap, are what any operand below them
    // makes.
    var filled_to: ?u128 = null;
    for (values.items) |value| {
        const expected: u128 = if (filled_to) |f| f + 1 else 0;
        if (value == expected) filled_to = expected else if (value > expected) break;
    }
    return .{ .tag = tag, .filled = filled_to orelse return null };
}

/// Whether a `@fromBackingInt` or `@enumFromInt` makes a value of its type from any operand
/// it is given: each value the operand can have is one the type holds.
pub fn fills(c: *Context, file: Project.FileId, call: Ast.Node.Index, operand: Ast.Node.Index) Context.Error!bool {
    for (widths(c)) |pointer| {
        const backing = (try backed(c, file, call, pointer)) orelse return false;
        // A type that fills its backing integer still holds no value past it: a wider or a
        // signed operand converts only where it is shown within it.
        if (!try nonnegative(c, file, operand, pointer)) return false;
        const magnitude = (try bound(c, file, operand, pointer, 0)) orelse return false;
        if (magnitude > backing.filled) return false;
    }
    return true;
}

/// Where the parameter `arg` is given to declares its type, where the call resolves.
fn argument(c: *Context, file: Project.FileId, call: Ast.full.Call, arg: Ast.Node.Index) Context.Error!?Destination {
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
fn field(c: *Context, file: Project.FileId, literal_node: Ast.Node.Index, value: Ast.Node.Index) Context.Error!?Facts.Decl {
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
    return decl;
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

/// A comparison that holds where a value is read: `small` below `large`, or at most it. Two
/// more forms only a position's judgement reads: `small` other than `large` (`differs`), and
/// `small` a position already read from the memory `large` (`read`: `m[i]` evaluated before,
/// so `i` is below `m`'s length).
const Fact = struct { small: Ast.Node.Index, large: Ast.Node.Index, strict: bool, differs: bool = false, read: bool = false };

/// The comparisons that hold where `node` is evaluated: the conditions of the branches and
/// loops it is in and of the `and` and `or` it is the right side of, and the negated
/// conditions of the earlier statements of its blocks that leave when they hold (`if (end >
/// buf.len) return error.Short;`). A comparison holds while nothing between it and `node`
/// assigns what it compares.
fn facts(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Fact {
    var out: std.ArrayList(Fact) = .empty;
    for (try gather(c, file, node)) |fact| if (!fact.differs and !fact.read) try out.append(c.allocator, fact);
    return out.items;
}

/// Every fact holding where `node` is evaluated, the forms only a position's judgement reads
/// with them: besides the comparisons, the positions read before it (a switch's operand
/// `m[i]`, a compared `m[i]`), what an aegis `assert.invariant` before it checked, and where
/// a std search a branch or loop takes the result of put that result.
fn gather(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Fact {
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
                    try subtracted(c, file, &out, statement, node);
                    try reserved(c, file, &out, statement, node);
                    try asserted(c, file, &out, statement, node);
                    try succeeded(c, file, &out, statement, node);
                    if (tree.fullVarDecl(statement)) |local| if (local.ast.init_node.unwrap()) |init| {
                        try searchFacts(c, file, &out, init, node);
                        try succeeded(c, file, &out, init, node);
                    };
                    const branch = tree.fullIf(statement) orelse continue;
                    if (branch.ast.else_expr != .none) continue;
                    if (leaves(tree, branch.ast.then_expr)) {
                        try held(c, file, &out, branch.ast.cond_expr, false, node);
                    } else try clamped(c, file, &out, branch, statement, node);
                }
            },
            .@"switch", .switch_comma => {
                const operand = tree.nodeData(parent).node_and_extra[0];
                if (operand != at) {
                    try read(c, file, &out, operand, node, null);
                    try succeeded(c, file, &out, operand, node);
                }
            },
            else => {
                if (tree.fullIf(parent)) |branch| {
                    if (branch.ast.cond_expr != at) try subtracted(c, file, &out, branch.ast.cond_expr, node);
                    if (branch.ast.then_expr == at) {
                        try held(c, file, &out, branch.ast.cond_expr, true, node);
                        if (branch.payload_token != null) try searchFacts(c, file, &out, branch.ast.cond_expr, node);
                    }
                    if (branch.ast.else_expr.unwrap() == at) try held(c, file, &out, branch.ast.cond_expr, false, node);
                } else if (tree.fullWhile(parent)) |loop| {
                    if (loop.ast.cond_expr != at) try subtracted(c, file, &out, loop.ast.cond_expr, node);
                    if (loop.ast.then_expr == at or loop.ast.cont_expr.unwrap() == at) {
                        try held(c, file, &out, loop.ast.cond_expr, true, node);
                        if (loop.payload_token != null) try searchFacts(c, file, &out, loop.ast.cond_expr, node);
                    }
                }
            },
        }
    }
    return out.items;
}

/// The position `access` reads, where it is `m[i]`: evaluated before the use, so `i` is below
/// `m`'s length there, while nothing between assigns either.
fn read(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), access: Ast.Node.Index, use: Ast.Node.Index, since: ?Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, access);
    if (tree.nodeTag(at) != .array_access) return;
    const memory, const index = tree.nodeData(at).node_and_node;
    if (!try kept(c, file, memory, since orelse access, use) or !try kept(c, file, index, since orelse access, use)) return;
    try out.append(c.allocator, .{ .small = index, .large = memory, .strict = true, .read = true });
}

/// What a difference computed before the use left: `a - b` of unsigned operands, evaluated on
/// every path through `statement` (`if (len > in.len - ip) return` before `in[ip..]`), puts
/// `b` at most `a` past it, while nothing between assigns either. A difference that would
/// underflow stops the program there, at the subtraction, which A010 judges itself.
fn subtracted(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    switch (tree.nodeTag(statement)) {
        .@"defer", .@"errdefer" => return,
        else => {},
    }
    const last = tree.lastToken(statement);
    const all = try differences(c, file);
    const Span = struct { tree: *const Ast, first: Ast.TokenIndex };
    const start = std.sort.partitionPoint(Ast.Node.Index, all, Span{ .tree = tree, .first = tree.firstToken(statement) }, struct {
        fn before(span: Span, node: Ast.Node.Index) bool {
            return span.tree.nodeMainToken(node) < span.first;
        }
    }.before);
    for (all[start..]) |difference| {
        if (tree.nodeMainToken(difference) > last) break;
        if (!always(c, file, difference, statement)) continue;
        const typed = try typeOf(c, file, difference, 64, 0);
        if (typed != .int or typed.int.signed) continue;
        const lhs, const rhs = tree.nodeData(difference).node_and_node;
        if (!try kept(c, file, lhs, difference, use) or !try kept(c, file, rhs, difference, use)) continue;
        try out.append(c.allocator, .{ .small = rhs, .large = lhs, .strict = false });
    }
}

/// The subtractions of each file, in source order, for `subtracted`.
const Differences = struct { files: std.AutoHashMapUnmanaged(usize, []const Ast.Node.Index) = .empty };

fn differences(c: *Context, file: Project.FileId) Context.Error![]const Ast.Node.Index {
    const memo = try c.facts.memo(Differences);
    const entry = try memo.files.getOrPut(c.allocator, file.raw());
    if (entry.found_existing) return entry.value_ptr.*;
    const tree = &c.project.files[file.raw()].tree;
    var found: std.ArrayList(Ast.Node.Index) = .empty;
    for (tree.nodes.items(.tag), 0..) |tag, i| if (tag == .sub) try found.append(c.allocator, @fromBackingInt(@intCast(i)));
    std.mem.sort(Ast.Node.Index, found.items, tree, struct {
        fn less(t: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
            return t.nodeMainToken(a) < t.nodeMainToken(b);
        }
    }.less);
    entry.value_ptr.* = found.items;
    return found.items;
}

/// Whether `node` is evaluated whenever `root`, which holds it, is: not in a branch's body, a
/// loop's body, a switch's prong, or the right side of an `and`, `or`, `orelse` or `catch`.
fn always(c: *Context, file: Project.FileId, node: Ast.Node.Index, root: Ast.Node.Index) bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    var at = node;
    while (at != root) {
        const parent = model.node_parents[@backingInt(at)] orelse return false;
        switch (tree.nodeTag(parent)) {
            .bool_and, .bool_or, .@"orelse", .@"catch" => if (tree.nodeData(parent).node_and_node[0] != at) return false,
            .@"switch", .switch_comma => if (tree.nodeData(parent).node_and_extra[0] != at) return false,
            .fn_decl, .@"defer", .@"errdefer" => return false,
            else => if (tree.fullIf(parent)) |branch| {
                if (branch.ast.cond_expr != at) return false;
            } else if (tree.fullWhile(parent)) |loop| {
                if (loop.ast.cond_expr != at) return false;
            } else if (tree.fullFor(parent)) |loop| {
                if (std.mem.findScalar(Ast.Node.Index, loop.ast.inputs, at) == null) return false;
            },
        }
        at = parent;
    }
    return true;
}

/// What a method call that succeeded checked: `try r.f(…)` where `f`, in this file, fails
/// unless a condition on its receiver holds, by `return if (c) … else error.X;` or by leading
/// `if (c) return error.X;` guards (`fn byte(self) !u8 { return if (self.at <
/// self.input.len) self.input[self.at] else error.SyntaxError; }`). The condition is read with
/// the receiver for the first parameter, so only where the call spells its receiver as `f`
/// names it and the condition names no other parameter; it holds from the call while nothing
/// after it assigns what it compares.
fn succeeded(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), value: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const attempt = bare(tree, value);
    if (tree.nodeTag(attempt) != .@"try") return;
    const call_node = tree.nodeData(attempt).node;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return;
    const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    if (callee != .function or !callee.function.file.eql(file)) return;
    const proto_node = model.declarations[callee.function.index].node;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, proto_node) orelse return;
    var parameters = proto.iterate(tree);
    const first = parameters.next() orelse return;
    const self_name = tree.tokenSlice(first.name_token orelse return);
    if (!std.mem.eql(u8, std.mem.trim(u8, tree.getNodeSource(receiver), " "), self_name)) return;
    const function = model.node_parents[@backingInt(proto_node)] orelse return; // safe: a declaration's node indexes its own tree's parent table.
    if (tree.nodeTag(function) != .fn_decl) return;
    var statement_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&statement_buffer, tree.nodeData(function).node_and_node[1]) orelse return;
    for (statements) |statement| {
        if (tree.nodeTag(statement) == .@"return") {
            const result = tree.nodeData(statement).opt_node.unwrap() orelse return;
            const branch = tree.fullIf(bare(tree, result)) orelse return;
            const otherwise = branch.ast.else_expr.unwrap() orelse return;
            if (!receiverOnly(tree, model, branch.ast.cond_expr, self_name)) return;
            if (tree.nodeTag(bare(tree, otherwise)) == .error_value) return holds(c, file, out, branch.ast.cond_expr, true, use, call_node);
            if (tree.nodeTag(bare(tree, branch.ast.then_expr)) == .error_value) return holds(c, file, out, branch.ast.cond_expr, false, use, call_node);
            return;
        }
        const branch = tree.fullIf(statement) orelse return;
        if (branch.ast.else_expr != .none or !failing(tree, branch.ast.then_expr) or !receiverOnly(tree, model, branch.ast.cond_expr, self_name)) return;
        try holds(c, file, out, branch.ast.cond_expr, false, use, call_node);
    }
}

/// Whether a callee's condition names no parameter but its first: what it says of the receiver
/// is what the caller's receiver holds.
fn receiverOnly(tree: *const Ast, model: anytype, condition: Ast.Node.Index, self_name: []const u8) bool {
    const first = tree.firstToken(condition);
    const last = tree.lastToken(condition);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const d = (model.reference(node) orelse continue).declaration orelse continue;
        if (model.declarations[d].kind == .parameter and !std.mem.eql(u8, model.declarations[d].name, self_name)) return false;
    }
    return true;
}

/// Whether a branch only fails: `return error.X;`, alone or as a block's one statement.
fn failing(tree: *const Ast, node: Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .@"return" => {
            const result = tree.nodeData(node).opt_node.unwrap() orelse return false;
            return tree.nodeTag(bare(tree, result)) == .error_value;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node).?;
            return statements.len == 1 and failing(tree, statements[0]);
        },
        else => return false,
    }
}

/// What an aegis `assert.invariant(condition, …)` statement checked: it stops the program in
/// every build where the condition fails, so the condition holds after it.
fn asserted(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, statement) orelse return;
    if (call.ast.params.len != 2) return;
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    if (callee != .function or try c.role(Metrics.library, callee) != .invariant) return;
    try held(c, file, out, call.ast.params[0], true, use);
}

/// Where a std search puts the position it found: `std.mem.findScalarPos(T, h, start, x)` and
/// the other `find…Pos` searches at or after `start`, every search of `h` below `h.len` (a
/// needle's search at most it: an empty needle is found at the end). `value` is the search, or
/// `search orelse <leave>`, which a capture or a constant then names (`alias`).
fn searchFacts(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), value: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const search = searched(tree, value) orelse return;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, search).?;
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    if (callee != .function) return;
    const name = c.project.models[callee.function.file.raw()].declarations[callee.function.index].name;
    const scalar = std.mem.startsWith(u8, name, "findScalar") or std.mem.startsWith(u8, name, "findAny");
    const from = std.mem.endsWith(u8, name, "Pos");
    if (!scalar and !std.mem.eql(u8, name, "find") and !std.mem.eql(u8, name, "findPos")) return;
    if (call.ast.params.len < (if (from) @as(usize, 4) else 3)) return;
    const path = try c.allocator.print("mem.{s}", .{name});
    const std_search = for ((try Governed.declarations(c, "std", path)) orelse return) |each| {
        if (std.meta.eql(each, callee.function)) break true;
    } else false;
    if (!std_search) return;
    const haystack = call.ast.params[1];
    if (!try kept(c, file, haystack, value, use)) return;
    // The search's value is the position its capture or constant names: below `h.len`.
    try out.append(c.allocator, .{ .small = search, .large = haystack, .strict = scalar, .read = true });
    if (from and try kept(c, file, call.ast.params[2], value, use)) try out.append(c.allocator, .{ .small = call.ast.params[2], .large = search, .strict = false });
}

/// The std search call `value` is, alone or before an `orelse` that leaves: a call spelled
/// `mem.find…` or `std.mem.find…`. Such a search is pure, so a capture or constant holding its
/// value is one value with the call while its arguments are kept.
fn searched(tree: *const Ast, value: Ast.Node.Index) ?Ast.Node.Index {
    var at = bare(tree, value);
    if (tree.nodeTag(at) == .@"orelse") {
        const lhs, const rhs = tree.nodeData(at).node_and_node;
        if (!leaves(tree, rhs)) return null;
        at = bare(tree, lhs);
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, at) orelse return null;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const namespace, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (!std.mem.startsWith(u8, tree.tokenSlice(name), "find")) return null;
    const spelled = tree.getNodeSource(namespace);
    if (!std.mem.eql(u8, spelled, "mem") and !std.mem.eql(u8, spelled, "std.mem")) return null;
    return at;
}

/// The comparisons `condition` gives where it is `truth`, and still holds at `use`.
fn held(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), condition: Ast.Node.Index, truth: bool, use: Ast.Node.Index) Context.Error!void {
    return holds(c, file, out, condition, truth, use, null);
}

/// `held`, with what is compared kept from `since` to `use` where given: a condition a callee
/// checked is read from its call, not from where the callee is written.
fn holds(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), condition: Ast.Node.Index, truth: bool, use: Ast.Node.Index, since: ?Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    const tag = tree.nodeTag(condition);
    switch (tag) {
        .grouped_expression => return holds(c, file, out, tree.nodeData(condition).node_and_token[0], truth, use, since),
        .bool_not => return holds(c, file, out, tree.nodeData(condition).node, !truth, use, since),
        .bool_and, .bool_or => {
            // Both sides hold where `a and b` does, and neither where `a or b` fails.
            if ((tag == .bool_and) != truth) return;
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            try holds(c, file, out, lhs, truth, use, since);
            try holds(c, file, out, rhs, truth, use, since);
        },
        .less_than, .less_or_equal, .greater_than, .greater_or_equal, .equal_equal, .bang_equal => {
            const lhs, const rhs = tree.nodeData(condition).node_and_node;
            // A compared `m[i]` was read: both sides are evaluated wherever the comparison's
            // truth is known.
            try read(c, file, out, lhs, use, since);
            try read(c, file, out, rhs, use, since);
            if (!try kept(c, file, lhs, since orelse condition, use) or !try kept(c, file, rhs, since orelse condition, use)) return;
            if (truth != (tag == .equal_equal) and (tag == .equal_equal or tag == .bang_equal)) {
                // Two values that differ: a position other than a length is below it where
                // another fact puts it at most the length.
                try out.append(c.allocator, .{ .small = lhs, .large = rhs, .strict = false, .differs = true });
            }
            const facts_of: []const Fact = switch (tag) {
                .less_than => if (truth) &.{.{ .small = lhs, .large = rhs, .strict = true }} else &.{.{ .small = rhs, .large = lhs, .strict = false }},
                .less_or_equal => if (truth) &.{.{ .small = lhs, .large = rhs, .strict = false }} else &.{.{ .small = rhs, .large = lhs, .strict = true }},
                .greater_than => if (truth) &.{.{ .small = rhs, .large = lhs, .strict = true }} else &.{.{ .small = lhs, .large = rhs, .strict = false }},
                .greater_or_equal => if (truth) &.{.{ .small = rhs, .large = lhs, .strict = false }} else &.{.{ .small = lhs, .large = rhs, .strict = true }},
                .equal_equal, .bang_equal => if (truth == (tag == .equal_equal))
                    &.{ .{ .small = lhs, .large = rhs, .strict = false }, .{ .small = rhs, .large = lhs, .strict = false } }
                else if (literal(tree, rhs) == 0 and try unsignedAll(c, file, lhs))
                    // An unsigned value other than zero is at least one; a signed one may be
                    // below zero.
                    &.{.{ .small = rhs, .large = lhs, .strict = true }}
                else if (literal(tree, lhs) == 0 and try unsignedAll(c, file, rhs))
                    &.{.{ .small = lhs, .large = rhs, .strict = true }}
                else
                    &.{},
                else => unreachable,
            };
            try out.appendSlice(c.allocator, facts_of);
            // `x -% 1 < a` of an unsigned `x` holds exactly where `1 <= x <= a`: at zero the
            // difference wraps to the type's greatest value, which nothing is below.
            for (facts_of) |fact| {
                if (!fact.strict) continue;
                const less = bare(tree, fact.small);
                if (tree.nodeTag(less) != .sub_wrap) continue;
                const x, const one = tree.nodeData(less).node_and_node;
                if (literal(tree, one) != 1 or !try unsignedAll(c, file, x)) continue;
                try out.append(c.allocator, .{ .small = x, .large = fact.large, .strict = false });
                try out.append(c.allocator, .{ .small = one, .large = x, .strict = false });
            }
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

/// The bound an aegis `bounded.Budget` reservation leaves where it passed: `try b.reserve(x)`,
/// `b.reserve(x) catch return …` or a local made from one (`var charge = b.reserve(x) catch
/// return …;`) charges `x` against the budget. `x` is the count itself, or a checked multiple or
/// sum of it (`int.Checked(usize).init(@sizeOf(T)).mul(n)`, read through a constant and
/// `.raw()`), which overflows to the error rather than wraps: the count is at most the budget.
fn reserved(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    var value = statement;
    if (tree.fullVarDecl(statement)) |local| value = local.ast.init_node.unwrap() orelse return;
    const reservation = passed(tree, value) orelse return;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, reservation) orelse return;
    if (call.ast.params.len != 1 or tree.nodeTag(call.ast.fn_expr) != .field_access) return;
    const receiver, const name = tree.nodeData(call.ast.fn_expr).node_and_token;
    if (!std.mem.eql(u8, tree.tokenSlice(name), "reserve")) return;
    if (try c.role(Contract.library, try c.facts.resolve(file, receiver)) != .budget) return;
    const count = (try charged(c, file, call.ast.params[0])) orelse return;
    if (!try kept(c, file, count, statement, use) or !try kept(c, file, receiver, statement, use)) return;
    try out.append(c.allocator, .{ .small = count, .large = receiver, .strict = false });
}

/// The call a statement passed: `try call`, or `call catch <leave>`.
fn passed(tree: *const Ast, value: Ast.Node.Index) ?Ast.Node.Index {
    return switch (tree.nodeTag(value)) {
        .@"try" => tree.nodeData(value).node,
        .@"catch" => blk: {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            break :blk if (leaves(tree, rhs)) lhs else null;
        },
        else => null,
    };
}

/// The count an amount charges: the amount, or `n` where it is a checked type's `.mul(n)` or
/// `.add(n)`, read through `.raw()` and a constant holding it.
fn charged(c: *Context, file: Project.FileId, amount: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    var at = bare(tree, amount);
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&buffer, at)) |raw| {
        if (raw.ast.params.len != 0 or tree.nodeTag(raw.ast.fn_expr) != .field_access) return at;
        const holder, const name = tree.nodeData(raw.ast.fn_expr).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(name), "raw")) return at;
        at = bare(tree, holder);
    }
    if (constantOf(c, file, at)) |variable| at = bare(tree, variable.ast.init_node.unwrap() orelse return null);
    if (passed(tree, at)) |inner| at = bare(tree, inner);
    const step = tree.fullCall(&buffer, at) orelse return at;
    if (step.ast.params.len != 1 or tree.nodeTag(step.ast.fn_expr) != .field_access) return null;
    const checked, const op = tree.nodeData(step.ast.fn_expr).node_and_token;
    const name = tree.tokenSlice(op);
    if (!std.mem.eql(u8, name, "mul") and !std.mem.eql(u8, name, "add")) return null;
    if (try c.role(Contract.library, try c.facts.resolve(file, checked)) != .scalar) return null;
    return step.ast.params[0];
}

/// The comparison a clamp leaves where it is done: `if (x > y) x = y;` puts `x` at most `y`
/// after it, and `if (x < y) x = y;` at least `y`, while nothing after assigns either.
fn clamped(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), branch: Ast.full.If, statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.files[file.raw()].tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements: []const Ast.Node.Index = tree.blockStatements(&buffer, branch.ast.then_expr) orelse &.{branch.ast.then_expr};
    const condition = bare(tree, branch.ast.cond_expr);
    // The clamp is the block's one assignment of a side of the condition to the other; the
    // block's other statements are assignments of neither (`n = r.at; status = .end_of_buffer;`).
    var clamp: ?Ast.Node.Index = null;
    for (statements) |statement_in| {
        if (tree.nodeTag(statement_in) != .assign) continue;
        const assigned_to = tree.nodeData(statement_in).node_and_node[0];
        const compared = switch (tree.nodeTag(condition)) {
            .greater_than, .greater_or_equal, .less_than, .less_or_equal => tree.nodeData(condition).node_and_node,
            else => return,
        };
        if (!same(tree, assigned_to, compared[0]) and !same(tree, assigned_to, compared[1])) continue;
        if (clamp != null) return;
        clamp = statement_in;
    }
    const then = clamp orelse return;
    for (statements) |other| {
        if (other == then) continue;
        switch (tree.nodeTag(other)) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat => {
                const lhs = tree.nodeData(other).node_and_node[0];
                if (same(tree, lhs, tree.nodeData(then).node_and_node[0]) or same(tree, lhs, tree.nodeData(then).node_and_node[1])) return;
            },
            else => return,
        }
    }
    const target, const value = tree.nodeData(then).node_and_node;
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

/// Whether nothing between a condition and a use can change what the condition compares. A
/// compared value that calls a function is never kept: each call may give another value. Past
/// the condition, a fact ends at a store to what it compares, by its name or through another
/// (`reads`, `Places`), and, where it reads exposed memory (a global, memory behind a pointer, a
/// local whose address is taken anywhere), at any store that may reach exposed memory, any call
/// but one that cannot write it (`inert`) and any builtin that writes memory. A loop around the
/// use that the condition is outside of runs its whole body again before the next use: each
/// store and call in it is between them too.
fn kept(c: *Context, file: Project.FileId, compared: Ast.Node.Index, condition: Ast.Node.Index, use: Ast.Node.Index) Context.Error!bool {
    return keptAcross(c, file, compared, condition, use, null);
}

/// `kept`, with a loop whose every pass is between the condition and the use (`also`): a `for`
/// whose inputs are read once, before the passes that each run its whole body.
fn keptAcross(c: *Context, file: Project.FileId, compared: Ast.Node.Index, condition: Ast.Node.Index, use: Ast.Node.Index, also: ?Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    if (literal(tree, compared) != null) return true;
    if (try varies(c, file, compared)) return false;
    const from = tree.lastToken(condition);
    const to = tree.firstToken(use);
    if (to <= from) return true;
    const model = &c.project.models[file.raw()];
    // A loop's continue expression sits between its condition and its body but runs after the
    // body, before the condition is checked again: `while (i < n) : (i += 1) use(b[i])`.
    const skipped: ?Ast.Node.Index = loop: {
        var at = condition;
        while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
            const loop = tree.fullWhile(parent) orelse continue;
            if (loop.ast.cond_expr != at) break :loop null;
            const body_first = tree.firstToken(loop.ast.then_expr);
            if (to < body_first or to > tree.lastToken(loop.ast.then_expr)) break :loop null;
            break :loop loop.ast.cont_expr.unwrap();
        }
        break :loop null;
    };
    // The loops around the use the condition is outside of: their back edges.
    var around: [8]Ast.Node.Index = undefined;
    var arounds: usize = 0;
    if (also) |loop| {
        around[0] = loop;
        arounds = 1;
    }
    {
        const guard = tree.firstToken(condition);
        var at = use;
        while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
            if (tree.nodeTag(parent) == .fn_decl) break;
            if (tree.fullWhile(parent) == null and tree.fullFor(parent) == null) continue;
            if (guard >= tree.firstToken(parent) and guard <= tree.lastToken(parent)) continue;
            // More loops than are kept: read as one around the whole function.
            if (arounds == around.len) return false;
            around[arounds] = parent;
            arounds += 1;
        }
    }
    const region: Region = .{ .tree = tree, .from = from, .to = to, .skipped = skipped, .loops = around[0..arounds] };
    // What the compared value reads, for the stores that reach it through other names.
    var places: Places = .{};
    try places.gather(c, file, compared, 0);
    const exposed = places.exposed();
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .assign, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat, .assign_destructure => {
                if (!region.holds(tree.nodeMainToken(node)) or apart(c, file, node, use, condition)) continue;
                // A use inside the assignment is read before its store (`x &= x - 1`).
                if (region.before(node)) continue;
                const targets: []const Ast.Node.Index = if (tag == .assign_destructure) tree.assignDestructure(node).ast.variables else &.{tree.nodeData(node).node_and_node[0]};
                for (targets) |target| {
                    // `_ = x` discards: it stores nothing.
                    if (tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) continue;
                    if (reads(c, file, compared, target, 0) or try places.written(c, file, target)) return false;
                    if (exposed and try places.aliased(c, file, target)) return false;
                }
            },
            .asm_simple, .@"asm" => {
                if (!region.holds(tree.nodeMainToken(node))) continue;
                // An `asm` may write any memory a pointer reaches, and its outputs by name.
                if (exposed) return false;
                const full = tree.fullAsm(node) orelse continue;
                for (full.outputs) |output| {
                    const out_name = tree.nodeData(output).opt_node_and_token[1] - 1;
                    if (tree.tokenTag(out_name) != .identifier) continue;
                    const at = bare(tree, compared);
                    for (tree.firstToken(at)..tree.lastToken(at) + 1) |k| {
                        if (std.mem.eql(u8, tree.tokenSlice(@intCast(k)), tree.tokenSlice(out_name))) return false;
                    }
                }
            },
            // Its address handed on (`advance(&i)`) lets what takes it write it.
            .address_of => {
                if (!region.holds(tree.nodeMainToken(node)) or apart(c, file, node, use, condition)) continue;
                if (reads(c, file, compared, tree.nodeData(node).node, 0)) return false;
                if (try places.written(c, file, tree.nodeData(node).node)) return false;
            },
            // Where the value reads exposed memory, any call that may write it, once its
            // arguments are read.
            .call_one, .call_one_comma, .call, .call_comma => {
                if (!region.holds(tree.nodeMainToken(node)) or apart(c, file, node, use, condition)) continue;
                if (region.before(node)) continue;
                if (exposed and !try inert(c, file, node)) return false;
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                if (!region.holds(tree.nodeMainToken(node)) or apart(c, file, node, use, condition)) continue;
                if (!writesMemory(tree.tokenSlice(tree.nodeMainToken(node)))) continue;
                if (region.before(node)) continue;
                if (exposed) return false;
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, node, &buffer)) |arg| if (reads(c, file, compared, arg, 0) or try places.written(c, file, arg)) return false;
            },
            else => {},
        }
    }
    return true;
}

/// Where a node runs between a condition and a use: past the condition and before the use
/// (a loop's continue expression aside, `skipped`), or anywhere in a loop around the use the
/// condition is outside of, whose back edge runs it again before the next use.
const Region = struct {
    tree: *const Ast,
    from: Ast.TokenIndex,
    to: Ast.TokenIndex,
    skipped: ?Ast.Node.Index,
    loops: []const Ast.Node.Index,

    /// Whether a node at `token` may run between the condition and the use.
    fn holds(r: @This(), token: Ast.TokenIndex) bool {
        return r.straight(token) or r.looped(token);
    }
    fn straight(r: @This(), token: Ast.TokenIndex) bool {
        if (token <= r.from or token >= r.to) return false;
        if (r.skipped) |cont| if (token >= r.tree.firstToken(cont) and token <= r.tree.lastToken(cont)) return false;
        return true;
    }
    fn looped(r: @This(), token: Ast.TokenIndex) bool {
        for (r.loops) |loop| if (token >= r.tree.firstToken(loop) and token <= r.tree.lastToken(loop)) return true;
        return false;
    }
    /// Whether a node holding the use runs before it on this pass only: on a back edge it
    /// runs before the next pass's use too.
    fn before(r: @This(), node: Ast.Node.Index) bool {
        return r.to <= r.tree.lastToken(node) and !r.looped(r.tree.nodeMainToken(node));
    }
};

/// Whether a builtin writes memory a pointer it is given reaches.
fn writesMemory(name: []const u8) bool {
    for ([_][]const u8{ "@memcpy", "@memset", "@memmove", "@atomicStore", "@atomicRmw", "@cmpxchgWeak", "@cmpxchgStrong" }) |writer| {
        if (std.mem.eql(u8, name, writer)) return true;
    }
    return false;
}

/// Whether an expression calls a function that may give another value each time: any but
/// std's `math.maxInt` and `math.minInt`, constants of the type they are given.
fn varies(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (tree.nodes.items(.tag), 0..) |tag, i| switch (tag) {
        .call_one, .call_one_comma, .call, .call_comma => {
            const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(at);
            if (token < first or token > last) continue;
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, at).?;
            const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |d| d,
                else => return true,
            };
            var constant_of_type = false;
            for ([_][]const u8{ "math.maxInt", "math.minInt" }) |path| {
                for ((try Governed.declarations(c, "std", path)) orelse &.{}) |each| constant_of_type = constant_of_type or std.meta.eql(each, decl);
            }
            if (!constant_of_type) return true;
        },
        else => {},
    };
    return false;
}

/// Whether a call cannot write the program's memory: a function of std's `mem`, `math`,
/// `ascii` or `unicode` namespaces, which hold no pointer of the program's, whose parameters
/// can carry none it could write through: a type, a value of a primitive type, or a `const`
/// pointer or slice of one (a type parameter's where the call gives it a primitive type). A
/// function parameter, `anytype`, a struct by value or a mutable pointer may reach anything.
fn inert(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        else => return false,
    };
    if (!try pure(c, decl.file)) return false;
    const callee = &c.project.files[decl.file.raw()].tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = callee.fullFnProto(&proto_buffer, c.project.models[decl.file.raw()].declarations[decl.index].node) orelse return false;
    // A method's receiver is its first parameter.
    var skip: usize = 0;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
        .instance, .pointer, .optional => skip = 1,
        else => {},
    };
    var it = proto.iterate(callee);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        const declared = param.type_expr orelse return false;
        var t = declared;
        if (callee.nodeTag(t) == .optional_type) t = callee.nodeData(t).node;
        if (callee.fullPtrType(t)) |pointer| {
            if (pointer.const_token == null) return false;
            t = pointer.ast.child_type;
        } else if (callee.nodeTag(t) == .identifier and std.mem.eql(u8, callee.tokenSlice(callee.nodeMainToken(t)), "type")) continue;
        if (callee.nodeTag(t) != .identifier) return false;
        const name = callee.tokenSlice(callee.nodeMainToken(t));
        if (Model.primitive(name) and !std.mem.eql(u8, name, "anyopaque")) continue;
        // A type parameter's: the type the call gives it.
        const typed_at = typeParameter(callee, proto, name) orelse return false;
        if (typed_at < skip) return false;
        const given = typed_at - skip;
        if (given >= call.ast.params.len) return false;
        const arg = call.ast.params[given];
        if (tree.nodeTag(arg) != .identifier or !Model.primitive(tree.tokenSlice(tree.nodeMainToken(arg))) or std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(arg)), "anyopaque")) return false;
    }
    return true;
}

/// The position of the `comptime T: type` parameter named `name`.
fn typeParameter(tree: *const Ast, proto: Ast.full.FnProto, name: []const u8) ?usize {
    var it = proto.iterate(tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        const token = param.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token), name)) continue;
        const declared = param.type_expr orelse return null;
        if (tree.nodeTag(declared) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(declared)), "type")) return null;
        return index;
    }
    return null;
}

/// The files of std's `mem`, `math`, `ascii` and `unicode` namespaces, and the files they reach
/// by their relative imports, found once for the run.
const Pure = struct { built: bool = false, files: std.AutoHashMapUnmanaged(u32, void) = .empty };

fn pure(c: *Context, file: Project.FileId) Context.Error!bool {
    const memo = try c.facts.memo(Pure);
    if (!memo.built) {
        memo.built = true;
        for ([_][]const u8{ "mem", "math", "ascii", "unicode" }) |namespace| {
            for ((try Governed.declarations(c, "std", namespace)) orelse &.{}) |decl| {
                const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
                if (value != .container) continue;
                var next: std.ArrayList(Project.FileId) = .empty;
                if (!(try memo.files.getOrPut(c.allocator, value.container.file.raw())).found_existing) try next.append(c.allocator, value.container.file);
                while (next.pop()) |at| for (c.project.imports) |mapping| {
                    if (!mapping.from.eql(at) or !std.mem.endsWith(u8, mapping.spelling, ".zig")) continue;
                    if ((try memo.files.getOrPut(c.allocator, mapping.target.raw())).found_existing) continue;
                    try next.append(c.allocator, mapping.target);
                };
            }
        }
    }
    return memo.files.contains(file.raw());
}

/// Whether a compared value reads what a store writes: the store's target spelled as a whole
/// part of it (`in` of `in.len`, `ip` of `ip + 1`, `s.buf` of `s.buf.len`; not `s.pos` of
/// `s.end`), or of the expression a constant it is names (`in_end` of `in.len - 32`).
fn reads(c: *Context, file: Project.FileId, compared: Ast.Node.Index, target: Ast.Node.Index, depth: u8) bool {
    const tree = &c.project.files[file.raw()].tree;
    const written_to = bare(tree, target);
    const want_first = tree.firstToken(written_to);
    const want = tree.lastToken(written_to) - want_first + 1;
    const at = bare(tree, compared);
    const first = tree.firstToken(at);
    const last = tree.lastToken(at);
    var start = first;
    while (start + want - 1 <= last) : (start += 1) {
        // A part begins where no `.` names it a field of something else.
        if (start > 0 and tree.tokenTag(start - 1) == .period) continue;
        for (0..want) |k| {
            const a: Ast.TokenIndex = @intCast(start + k);
            const b: Ast.TokenIndex = @intCast(want_first + k);
            if (tree.tokenTag(a) != tree.tokenTag(b) or !std.mem.eql(u8, tree.tokenSlice(a), tree.tokenSlice(b))) break;
        } else {
            // And ends where nothing continues it but a field, an index or a call on it.
            const next = start + want;
            if (next > last or tree.tokenTag(next) != .identifier) return true;
        }
    }
    if (depth < 4) if (constantOf(c, file, at)) |local| if (local.ast.init_node.unwrap()) |init| return reads(c, file, init, target, depth + 1);
    return false;
}

/// A place in memory an expression names: the declaration it starts at and the parts on the
/// way, a field by its name and any index as `[]` (`s.buf.len` is `s`, then `buf`, `len`).
/// Dereferences add no part, as a field reaches through a pointer alike.
const Place = struct {
    decl: u32,
    parts: [8][]const u8 = undefined,
    len: u8 = 0,
    /// Whether a name other than its own may write it: a container-level variable, memory
    /// behind a pointer, or a local whose address is taken (`addressed`).
    exposed: bool = false,
    /// Whether it lies in one struct, not a union: its declaration's own, or the one its
    /// pointer leads to, past no other pointer. Two such places of one declaration that part
    /// at a field are apart.
    flat: bool = false,
};

fn placeOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Place {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    // The parts come from the outside in; the eight nearest the declaration are kept.
    var ring: [8][]const u8 = undefined;
    var count: usize = 0;
    var exposed = false;
    // Whether a pointer is followed past the declaration's own step.
    var deep = false;
    var at = bare(tree, node);
    while (tree.nodeTag(at) != .identifier) {
        const part: ?[]const u8, const inner = switch (tree.nodeTag(at)) {
            .field_access => .{ tree.tokenSlice(tree.nodeData(at).node_and_token[1]), tree.nodeData(at).node_and_token[0] },
            .array_access => .{ "[]", tree.nodeData(at).node_and_node[0] },
            .unwrap_optional => .{ null, tree.nodeData(at).node_and_token[0] },
            .deref => .{ null, tree.nodeData(at).node },
            else => return null,
        };
        const follows = switch (tree.nodeTag(at)) {
            .field_access => try fieldFollows(c, file, inner, part.?),
            .array_access => (try c.facts.resolve(file, inner)) != .array,
            .deref => true,
            else => false,
        };
        if (follows) {
            exposed = true;
            if (tree.nodeTag(bare(tree, inner)) != .identifier) deep = true;
        }
        if (part) |name| {
            ring[count % ring.len] = name;
            count += 1;
        }
        at = bare(tree, inner);
    }
    const d = (model.reference(at) orelse return null).declaration orelse return null;
    const record = model.declarations[d];
    const scope = model.scopes[record.scope].kind;
    if (record.kind == .variable and (scope == .file or scope == .container)) exposed = true;
    if (!exposed and try addressed(c, file, d)) exposed = true;
    var out: Place = .{ .decl = d, .exposed = exposed };
    while (out.len < @min(count, ring.len)) : (out.len += 1) out.parts[out.len] = ring[(count - 1 - out.len) % ring.len];
    out.flat = !deep and out.len > 0 and !std.mem.eql(u8, out.parts[0], "[]") and try structured(c, file, at);
    return out;
}

/// Whether reading the field `name` of `receiver` follows a pointer: a single pointer's field
/// does, a slice's `len` and `ptr` do not (unless what it points to has a field of the name),
/// and a field of a container named as a namespace is a container-level variable's. A receiver
/// the reading does not know may be either: read as following one.
fn fieldFollows(c: *Context, file: Project.FileId, receiver: Ast.Node.Index, name: []const u8) Context.Error!bool {
    return switch (try c.facts.resolve(file, receiver)) {
        .pointer => |inner| blk: {
            if (!std.mem.eql(u8, name, "len") and !std.mem.eql(u8, name, "ptr")) break :blk true;
            break :blk switch (inner.*) {
                .instance, .container => |k| c.facts.member(k, name) != null,
                .primitive, .array, .pointer, .optional, .scalar => false,
                else => true,
            };
        },
        .instance, .array, .literal, .reified, .primitive, .scalar, .error_union, .optional, .error_set, .function, .fn_type => false,
        else => true,
    };
}

/// Whether a declaration's value is a struct (not a union), or a single pointer to one.
fn structured(c: *Context, file: Project.FileId, root: Ast.Node.Index) Context.Error!bool {
    var value = try c.facts.resolve(file, root);
    if (value == .pointer) value = value.pointer.*;
    const k = switch (value) {
        .instance => |k| k,
        else => return false,
    };
    const tree = &c.project.files[k.file.raw()].tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const declared = tree.fullContainerDecl(&buffer, c.project.models[k.file.raw()].scopes[k.scope].node) orelse return false;
    return tree.tokenTag(declared.ast.main_token) == .keyword_struct;
}

/// Whether a function's local or parameter may be written by another name: its address is
/// taken (`&x`, `&x.f`), a method is called on it (which may take its address), a capture
/// binds a pointer into it (`if (x) |*p|`), or an `asm` output names it. Found once per
/// declaration.
const Addressed = struct { map: std.AutoHashMapUnmanaged(struct { u32, u32 }, bool) = .empty };

fn addressed(c: *Context, file: Project.FileId, d: u32) Context.Error!bool {
    const memo = try c.facts.memo(Addressed);
    const key = .{ file.raw(), d };
    if (memo.map.get(key)) |known| return known;
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const found = found: {
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            switch (tag) {
                // An address discarded (`_ = &x;`) reaches nothing.
                .address_of => if (rootOf(tree, model, tree.nodeData(node).node) == d and !discarded(tree, model, node)) break :found true,
                .call_one, .call_one_comma, .call, .call_comma => {
                    var buffer: [1]Ast.Node.Index = undefined;
                    const call = tree.fullCall(&buffer, node).?;
                    if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
                    if (rootOf(tree, model, tree.nodeData(call.ast.fn_expr).node_and_token[0]) == d) break :found true;
                },
                .asm_output => if (outputNames(tree, node, model.declarations[d].name)) break :found true,
                else => {},
            }
        }
        for (model.declarations) |decl| {
            if (decl.kind != .capture or decl.token == 0 or tree.tokenTag(decl.token - 1) != .asterisk) continue;
            const operand: ?Ast.Node.Index = if (tree.fullIf(decl.node)) |branch| branch.ast.cond_expr else if (tree.fullWhile(decl.node)) |loop| loop.ast.cond_expr else if (tree.fullSwitchCase(decl.node) != null) blk: {
                const choice = model.node_parents[@backingInt(decl.node)] orelse break :blk null; // safe: a node index indexes its own tree's parent table.
                break :blk if (tree.fullSwitch(choice)) |whole| whole.ast.condition else null;
            } else if (tree.fullFor(decl.node)) |loop| blk: {
                for (loop.ast.inputs) |each| if (rootOf(tree, model, each) == d) break :blk each;
                break :blk null;
            } else null;
            if (operand) |each| if (rootOf(tree, model, each) == d) break :found true;
        }
        break :found false;
    };
    try memo.map.put(c.allocator, key, found);
    return found;
}

/// Whether a value is discarded: `_ = value;`.
fn discarded(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const parent = model.node_parents[@backingInt(node)] orelse return false; // safe: a node index indexes its own tree's parent table.
    if (tree.nodeTag(parent) != .assign) return false;
    const target, const value = tree.nodeData(parent).node_and_node;
    return value == node and tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_");
}

/// The declaration an expression names memory of, past fields, indexes and unwraps but not a
/// dereference: `x` of `x.f[i]`, none of `p.*`.
fn rootOf(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?u32 {
    var at = node;
    while (true) switch (tree.nodeTag(at)) {
        .identifier => return (model.reference(at) orelse return null).declaration,
        .field_access, .unwrap_optional, .grouped_expression => at = tree.nodeData(at).node_and_token[0],
        .array_access => at = tree.nodeData(at).node_and_node[0],
        .slice_open, .slice, .slice_sentinel => at = (tree.fullSlice(at) orelse return null).ast.sliced,
        else => return null,
    };
}

/// The places a compared value reads: each named in it, and those of the constants it names.
const Places = struct {
    items: [8]Place = undefined,
    len: u8 = 0,
    /// More places than are kept: read as exposed.
    over: bool = false,

    fn add(self: *Places, place: Place) void {
        if (self.len == self.items.len) {
            self.over = true;
            return;
        }
        self.items[self.len] = place;
        self.len += 1;
    }

    fn gather(self: *Places, c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!void {
        if (depth >= 4) return;
        const tree = &c.project.files[file.raw()].tree;
        const at = bare(tree, node);
        if (try placeOf(c, file, at)) |place| {
            self.add(place);
            if (constantOf(c, file, at)) |local| if (local.ast.init_node.unwrap()) |init| try self.gather(c, file, init, depth + 1);
        }
        switch (tree.nodeTag(at)) {
            .add, .sub, .mul, .div, .mod, .shl, .shr, .bit_and, .bit_or, .bit_xor, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .shl_sat, .array_access => {
                const lhs, const rhs = tree.nodeData(at).node_and_node;
                if (tree.nodeTag(at) != .array_access) try self.gather(c, file, lhs, depth + 1);
                try self.gather(c, file, rhs, depth + 1);
            },
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, at, &buffer)) |arg| try self.gather(c, file, arg, depth + 1);
            },
            else => {},
        }
    }

    /// Whether any place may be written by another name.
    fn exposed(self: *const Places) bool {
        if (self.over) return true;
        for (self.items[0..self.len]) |place| if (place.exposed) return true;
        return false;
    }

    /// Whether storing to `target` writes one of the places by its own name: one memory, or
    /// the parts of one leading into the other's.
    fn written(self: *const Places, c: *Context, file: Project.FileId, target: Ast.Node.Index) Context.Error!bool {
        const place = (try placeOf(c, file, target)) orelse return false;
        for (self.items[0..self.len]) |each| if (overlaps(place, each)) return true;
        return false;
    }

    /// Whether a store to `target` may write an exposed place through another name: it may
    /// reach exposed memory (`aliases`), unless it and each exposed place are fields of one
    /// struct that part (`self.pos` beside `self.buf.len`).
    fn aliased(self: *const Places, c: *Context, file: Project.FileId, target: Ast.Node.Index) Context.Error!bool {
        if (self.over) return true;
        const store = (try placeOf(c, file, target)) orelse return self.exposed();
        if (!store.exposed) return false;
        for (self.items[0..self.len]) |place| {
            if (!place.exposed) continue;
            if (store.decl == place.decl and store.flat and place.flat and !std.mem.eql(u8, store.parts[0], place.parts[0])) continue;
            return true;
        }
        return false;
    }
};

/// Whether two places of one declaration overlap: their parts agree as far as both go.
fn overlaps(a: Place, b: Place) bool {
    if (a.decl != b.decl) return false;
    const n = @min(a.len, b.len);
    for (a.parts[0..n], b.parts[0..n]) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Whether `assignment` and `use` are in branches no path takes both of: one in an `if`'s
/// then branch and the other in its `else`, or in two prongs of one switch, with no loop
/// between that branching and `since` (the comparison), which would run one branch and then
/// the other.
fn apart(c: *Context, file: Project.FileId, assignment: Ast.Node.Index, use: Ast.Node.Index, since: Ast.Node.Index) bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const token = tree.firstToken(use);
    const inside = struct {
        fn range(t: *const Ast, node: Ast.Node.Index, at: Ast.TokenIndex) bool {
            return at >= t.firstToken(node) and at <= t.lastToken(node);
        }
    }.range;
    var at = assignment;
    while (model.node_parents[@backingInt(at)]) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return false;
        const exclusive = exclusive: {
            if (tree.fullIf(parent)) |branch| {
                const otherwise = branch.ast.else_expr.unwrap() orelse break :exclusive false;
                break :exclusive (at == branch.ast.then_expr and inside(tree, otherwise, token)) or (at == otherwise and inside(tree, branch.ast.then_expr, token));
            }
            if (tree.fullSwitchCase(at) == null or inside(tree, at, token)) break :exclusive false;
            const s = tree.fullSwitch(parent) orelse break :exclusive false;
            for (s.ast.cases) |case| if (case != at and inside(tree, case, token)) break :exclusive true;
            break :exclusive false;
        };
        if (!exclusive) continue;
        // A loop around the branching that `since` is outside of runs both branches in turn.
        const guard = tree.firstToken(since);
        var around = parent;
        while (model.node_parents[@backingInt(around)]) |outer| : (around = outer) {
            if (tree.nodeTag(outer) == .fn_decl) break;
            if ((tree.fullWhile(outer) != null or tree.fullFor(outer) != null) and !inside(tree, outer, guard)) return false;
        }
        return true;
    }
    return false;
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
    if (same(tree, rhs, lhs)) return true;
    // A difference of unsigned operands is at most what it is taken from (were it to underflow,
    // the program stops there, at the subtraction A010 judges itself).
    const taken_from = bare(tree, rhs);
    if (tree.nodeTag(taken_from) == .sub and same(tree, tree.nodeData(taken_from).node_and_node[0], lhs)) {
        const typed = try typeOf(c, file, taken_from, pointer, 0);
        if (typed == .int and !typed.int.signed) return true;
    }
    // A constant minimum is at most each of its arguments: at most `lhs` where one is, and
    // nothing between assigns `lhs` (`const n = @min(max, op - start);` before `op - n`).
    if (constantOf(c, file, bare(tree, rhs))) |local| if (local.ast.init_node.unwrap()) |init| {
        const call = bare(tree, init);
        switch (tree.nodeTag(call)) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(call)), "@min") and try kept(c, file, lhs, call, node)) {
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, call, &buffer)) |arg| if (try ordered(c, file, node, lhs, arg, pointer)) return true;
            },
            else => {},
        }
    };
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
    if (captured(c, file, bare(tree, node))) |search| return search;
    const variable = constantOf(c, file, bare(tree, node)) orelse return null;
    if (searched(tree, variable.ast.init_node.unwrap() orelse return null)) |search| return search;
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

/// The search a capture names: `|x|` of `while (search) |x|` or `if (search) |x|`, the call's
/// value unwrapped.
fn captured(c: *Context, file: Project.FileId, node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    if (tree.nodeTag(node) != .identifier) return null;
    const model = &c.project.models[file.raw()];
    const d = (model.reference(node) orelse return null).declaration orelse return null;
    if (model.declarations[d].kind != .capture) return null;
    const owner = model.declarations[d].node;
    const condition = if (tree.fullWhile(owner)) |loop| loop.ast.cond_expr else if (tree.fullIf(owner)) |branch| branch.ast.cond_expr else return null;
    return searched(tree, condition);
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
    // A remainder by the memory's length is below it (a zero length stops the remainder), and
    // so is a `for` counter over its length or beside it.
    if (try remainderOf(c, file, index, memory)) return true;
    if (try counted(c, file, index, memory)) return true;
    const held_here = try gather(c, file, index);
    for (widths(c)) |pointer| {
        if (try fixedLength(c, file, memory)) |n| {
            const most = (try bound(c, file, index, pointer, 0)) orelse return false;
            if (if (end) most <= n else most < n) continue;
        }
        if (!try keeps(c, file, held_here, index, memory, end)) return false;
    }
    return true;
}

/// Whether `index` is a remainder by `memory`'s length of a value at zero or above: `x %
/// m.len`, `@mod(x, m.len)`, `@rem(x, m.len)`.
fn remainderOf(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, index);
    const dividend, const divisor = switch (tree.nodeTag(at)) {
        .mod => tree.nodeData(at).node_and_node,
        .builtin_call_two, .builtin_call_two_comma => blk: {
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            if (!std.mem.eql(u8, name, "@mod") and !std.mem.eql(u8, name, "@rem")) return false;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, at, &buffer);
            if (args.len != 2) return false;
            break :blk .{ args[0], args[1] };
        },
        else => return false,
    };
    if (!lengthOf(c, file, divisor, memory) or try varies(c, file, memory)) return false;
    for (widths(c)) |pointer| if (!try nonnegative(c, file, dividend, pointer)) return false;
    return true;
}

/// Whether `index` is a `for` loop's counter below `memory`'s length, its range ending there
/// (`for (0..m.len) |i|`) or the loop taking `memory` first beside it (`for (m, 0..) |x, i|`),
/// and nothing in the loop changes the memory: its inputs are read once, before every pass.
fn counted(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    const at = bare(tree, index);
    if (tree.nodeTag(at) != .identifier) return false;
    const d = (model.reference(at) orelse return false).declaration orelse return false;
    const record = model.declarations[d];
    if (record.kind != .capture) return false;
    const loop = tree.fullFor(record.node) orelse return false;
    var taken: usize = 0;
    for (model.declarations[0..d]) |earlier| if (earlier.kind == .capture and earlier.node == record.node) {
        taken += 1;
    };
    if (taken >= loop.ast.inputs.len or tree.nodeTag(loop.ast.inputs[taken]) != .for_range) return false;
    const start, const end = tree.nodeData(loop.ast.inputs[taken]).node_and_opt_node;
    if (literal(tree, start) != 0) return false;
    // The loop runs as many passes as its first input has elements; Zig checks the others
    // match only where safety is on.
    const bounded = if (end.unwrap()) |e| lengthOf(c, file, e, memory) else same(tree, loop.ast.inputs[0], memory);
    if (!bounded or try varies(c, file, memory)) return false;
    return keptAcross(c, file, memory, loop.ast.inputs[loop.ast.inputs.len - 1], index, record.node);
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

/// Whether the facts keep `index` within `memory`'s length (at most it, for a slice's end), in
/// the forms a parser checks a position: `i < buf.len`, `i + 4 <= buf.len`, `buf.len - i >= 4`
/// (or the check that leaves where it fails, `if (buf.len - i < 4) return`), `buf[i]` read
/// before, one step through another comparison (`a <= b and b <= buf.len`), and a position
/// other than the length where another fact puts it at most the length (`i < buf.len` and
/// `i + 1 != buf.len` put `i + 1` below it). A constant local naming the index or the length
/// (`const off = at;`, `const n = buf.len;`), or a capture naming a search, is read as it.
fn keeps(c: *Context, file: Project.FileId, held_here: []const Fact, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    const tree = &c.project.files[file.raw()].tree;
    const index_base, const j = shift(tree, index);
    // `index_base + most` is at most the length.
    var most: ?i128 = null;
    for (held_here) |fact| {
        if (fact.differs) continue;
        if (try covered(c, file, fact, index, memory, end)) return true;
        if (fact.read) {
            if (!same(tree, fact.large, memory)) continue;
            const base, const k = shift(tree, fact.small);
            const step: i128 = @intFromBool(fact.strict);
            if (oneValue(c, file, base, index_base)) most = @max(most orelse (k + step), k + step);
            continue;
        }
        if (lengthOf(c, file, fact.large, memory)) {
            const base, const k = shift(tree, fact.small);
            const step: i128 = @intFromBool(fact.strict);
            if (oneValue(c, file, base, index_base)) most = @max(most orelse (k + step), k + step);
            continue;
        }
        if (remains(c, file, fact, index, memory, end)) return true;
        // One step through another fact: `a <= b` and `b <= length`.
        for (held_here) |next| {
            if (next.differs or next.read or !lengthOf(c, file, next.large, memory) or !oneValue(c, file, fact.large, next.small)) continue;
            const base, const k = shift(tree, fact.small);
            const step: i128 = @as(i128, @intFromBool(fact.strict)) + @intFromBool(next.strict);
            if (oneValue(c, file, base, index_base)) most = @max(most orelse (k + step), k + step);
        }
    }
    var m = most orelse return false;
    // `index_base + m` at most the length and other than it: below it.
    var moved = true;
    while (moved) {
        moved = false;
        for (held_here) |fact| {
            if (!fact.differs) continue;
            const spot = if (lengthOf(c, file, fact.large, memory)) fact.small else if (lengthOf(c, file, fact.small, memory)) fact.large else continue;
            const base, const k = shift(tree, spot);
            if (k == m and oneValue(c, file, base, index_base)) {
                m += 1;
                moved = true;
            }
        }
    }
    return if (end) j <= m else j < m;
}

/// Whether a sum the length bounds covers the position: `l1 + l2 + 6 <= in.len` keeps
/// `in[6 + l1 ..]` and `in[6..][0..l1]`. The position's parts, with the starts of the slices
/// it is taken from, are each a part of the sum, and the sum's other parts are unsigned, so
/// the position is at most the sum.
fn covered(c: *Context, file: Project.FileId, fact: Fact, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    if (fact.differs or fact.read) return false;
    const tree = &c.project.files[file.raw()].tree;
    var needed: Terms = .{};
    var base = bare(tree, memory);
    while (tree.nodeTag(base) == .slice_open) {
        const slice = tree.fullSlice(base).?;
        if (!try needed.add(c, file, slice.ast.start, 0)) return false;
        base = bare(tree, slice.ast.sliced);
    }
    if (!try needed.add(c, file, index, 0)) return false;
    var whole: Terms = .{};
    // A length less a constant (`x <= in.len - 32`, or a constant naming it, `in_end`) is
    // the length with the constant on the other side: reached, the difference did not
    // underflow, so `x + 32 <= in.len`.
    var large = bare(tree, fact.large);
    if (tree.nodeTag(large) != .sub) if (constantOf(c, file, large)) |local| if (local.ast.init_node.unwrap()) |init| {
        large = bare(tree, init);
    };
    if (tree.nodeTag(large) == .sub) {
        const whole_length, const margin = tree.nodeData(large).node_and_node;
        const k = (try valueOf(c, file, bare(tree, margin), 0)) orelse return false;
        if (!lengthOf(c, file, whole_length, base)) return false;
        whole.constant += k;
    } else if (!lengthOf(c, file, fact.large, base)) return false;
    if (!try whole.add(c, file, fact.small, 0) or whole.len == 0 or (whole.len < 2 and whole.constant == 0)) return false;
    var used: [Terms.capacity]bool = @splat(false);
    for (needed.nodes[0..needed.len]) |term| {
        for (whole.nodes[0..whole.len], 0..) |part, i| {
            if (used[i] or !oneValue(c, file, part, term)) continue;
            used[i] = true;
            break;
        } else return false;
    }
    for (whole.nodes[0..whole.len], used[0..whole.len]) |part, taken| if (!taken) {
        const typed = try typeOf(c, file, part, 64, 0);
        if (typed != .int or typed.int.signed) return false;
    };
    const room = whole.constant + @intFromBool(fact.strict) - needed.constant;
    return if (end) room >= 0 else room >= 1;
}

/// The argument a call passes through unchanged: a function of one parameter each of whose
/// returns is that parameter, or an `asm` with an empty template whose one output is tied
/// (`"0"`) to its one input, the parameter, as an optimization barrier is (warp's
/// `chainless(ip + 3)` is `ip + 3`).
fn identity(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.files[file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (call.ast.params.len != 1) return null;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        else => return null,
    };
    const model = &c.project.models[decl.file.raw()];
    const callee = &c.project.files[decl.file.raw()].tree;
    const proto_node = model.declarations[decl.index].node;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = callee.fullFnProto(&proto_buffer, proto_node) orelse return null;
    var params = proto.iterate(callee);
    const param = params.next() orelse return null;
    if (params.next() != null) return null;
    const name = callee.tokenSlice(param.name_token orelse return null);
    const fn_decl = model.node_parents[@backingInt(proto_node)] orelse return null; // safe: a node index indexes its own tree's parent table.
    if (callee.nodeTag(fn_decl) != .fn_decl) return null;
    const body = callee.nodeData(fn_decl).node_and_node[1];
    var returns: usize = 0;
    for (callee.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (callee.nodeMainToken(at) < callee.firstToken(body) or callee.nodeMainToken(at) > callee.lastToken(body)) continue;
        const value = callee.nodeData(at).opt_node.unwrap() orelse return null;
        if (!passes(callee, value, name, 0)) return null;
        returns += 1;
    }
    return if (returns == 0) null else call.ast.params[0];
}

/// Whether an expression is the parameter `name` unchanged: itself, a branch or prong each of
/// which is, or an empty `asm` tying its output to it.
fn passes(tree: *const Ast, node: Ast.Node.Index, name: []const u8, depth: u8) bool {
    if (depth > 4) return false;
    const at = bare(tree, node);
    switch (tree.nodeTag(at)) {
        .identifier => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), name),
        .@"switch", .switch_comma => {
            const full = tree.fullSwitch(at).?;
            for (full.ast.cases) |case| if (!passes(tree, tree.fullSwitchCase(case).?.ast.target_expr, name, depth + 1)) return false;
            return true;
        },
        else => {
            if (tree.fullIf(at)) |branch| {
                const otherwise = branch.ast.else_expr.unwrap() orelse return false;
                return passes(tree, branch.ast.then_expr, name, depth + 1) and passes(tree, otherwise, name, depth + 1);
            }
            const asm_node = tree.fullAsm(at) orelse return false;
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(asm_node.ast.template)), "\"\"")) return false;
            if (asm_node.outputs.len != 1 or asm_node.inputs.len != 1) return false;
            const input = asm_node.inputs[0];
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(input) + 2), "\"0\"")) return false;
            const operand = tree.nodeData(input).node_and_token[0];
            return tree.nodeTag(operand) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(operand)), name);
        },
    }
}

/// A constant's value: a literal, a sum, difference or product of constants, or a constant
/// declaration naming one, in this file or another (`margin`, `bits_.margin`, `258 + 16`).
fn valueOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!?u64 {
    if (depth > 4) return null;
    const tree = &c.project.files[file.raw()].tree;
    const at = bare(tree, node);
    if (literal(tree, at)) |k| return k;
    switch (tree.nodeTag(at)) {
        .add, .sub, .mul => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            const a = (try valueOf(c, file, lhs, depth + 1)) orelse return null;
            const b = (try valueOf(c, file, rhs, depth + 1)) orelse return null;
            return switch (tree.nodeTag(at)) {
                .add => std.math.add(u64, a, b) catch null,
                .sub => std.math.sub(u64, a, b) catch null,
                else => std.math.mul(u64, a, b) catch null,
            };
        },
        .identifier, .field_access => {
            const decl = (try c.facts.definition(file, at)) orelse return null;
            const model = &c.project.models[decl.file.raw()];
            const record = model.declarations[decl.index];
            if (record.kind != .variable) return null;
            const declared = &c.project.files[decl.file.raw()].tree;
            const variable = declared.fullVarDecl(record.node) orelse return null;
            if (declared.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
            return valueOf(c, decl.file, variable.ast.init_node.unwrap() orelse return null, depth + 1);
        },
        else => return null,
    }
}

/// A sum as its parts and the constants added in it: `6 + l1 + l2` is `l1`, `l2` and 6, and
/// a constant naming a sum is that sum (`const records_at = id_end + 4;`).
const Terms = struct {
    const capacity = 8;
    nodes: [capacity]Ast.Node.Index = undefined,
    len: usize = 0,
    constant: i128 = 0,

    fn add(terms: *Terms, c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
        const tree = &c.project.files[file.raw()].tree;
        const at = bare(tree, node);
        if (try valueOf(c, file, at, 0)) |k| {
            terms.constant += k;
            return true;
        }
        if (tree.nodeTag(at) == .add) {
            const a, const b = tree.nodeData(at).node_and_node;
            return try terms.add(c, file, a, depth) and try terms.add(c, file, b, depth);
        }
        // Less a constant: the sum and the constant taken off it.
        if (tree.nodeTag(at) == .sub) {
            const a, const b = tree.nodeData(at).node_and_node;
            if (try valueOf(c, file, b, 0)) |k| {
                terms.constant -= k;
                return terms.add(c, file, a, depth);
            }
        }
        if (depth < 4) {
            if (try identity(c, file, at)) |through| return terms.add(c, file, through, depth + 1);
            if (constantOf(c, file, at)) |local| if (local.ast.init_node.unwrap()) |init| {
                switch (tree.nodeTag(bare(tree, init))) {
                    .add, .sub => return terms.add(c, file, init, depth + 1),
                    else => if (try identity(c, file, bare(tree, init)) != null) return terms.add(c, file, init, depth + 1),
                }
            };
        }
        if (terms.len == capacity) return false;
        terms.nodes[terms.len] = at;
        terms.len += 1;
        return true;
    }
};

/// What is left after `index` is at least `k`, or above zero: `index` is below the length.
fn remains(c: *Context, file: Project.FileId, fact: Fact, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) bool {
    const tree = &c.project.files[file.raw()].tree;
    const large = bare(tree, fact.large);
    if (tree.nodeTag(large) != .sub) return false;
    const whole, const taken = tree.nodeData(large).node_and_node;
    if (!lengthOf(c, file, whole, memory) or !oneValue(c, file, index, taken)) return false;
    const k = literal(tree, fact.small) orelse return false;
    return k >= 1 or (k == 0 and (fact.strict or end));
}

/// An expression as a base and a constant added to it or taken from it: `a + 4` is `a` and 4,
/// `a - 1` is `a` and -1, `a` is `a` and 0.
fn shift(tree: *const Ast, node: Ast.Node.Index) struct { Ast.Node.Index, i128 } {
    const at = bare(tree, node);
    switch (tree.nodeTag(at)) {
        .add => {
            const a, const b = tree.nodeData(at).node_and_node;
            if (literal(tree, b)) |k| return .{ a, k };
            if (literal(tree, a)) |k| return .{ b, k };
        },
        .sub => {
            const a, const b = tree.nodeData(at).node_and_node;
            if (literal(tree, b)) |k| return .{ a, -@as(i128, k) };
        },
        else => {},
    }
    return .{ at, 0 };
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

/// Whether a value is std's `mem.Allocator`.
fn allocator(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    var value_of = try c.facts.resolve(file, node);
    if (value_of == .pointer) value_of = value_of.pointer.*;
    const k = switch (value_of) {
        .instance => |k| k,
        else => return false,
    };
    for ((try Governed.declarations(c, "std", "mem.Allocator")) orelse return false) |decl| {
        const value = try c.facts.declaration((try c.facts.origin(decl)) orelse decl);
        if (value == .container and value.container.file.eql(k.file) and value.container.scope == k.scope) return true;
    }
    return false;
}

/// The union field a prong's capture takes by value (`.set => |s|`): the prong's one item names
/// it, and the switch's operand is a union declaring it.
fn prongField(c: *Context, capture: Facts.Decl) Context.Error!?Facts.Decl {
    const model = &c.project.models[capture.file.raw()];
    const tree = &c.project.files[capture.file.raw()].tree;
    const case_node = model.declarations[capture.index].node;
    const case = tree.fullSwitchCase(case_node) orelse return null;
    const payload = case.payload_token orelse return null;
    if (tree.tokenTag(payload) == .asterisk or case.ast.values.len != 1) return null;
    const item = case.ast.values[0];
    if (tree.nodeTag(item) != .enum_literal) return null;
    const switch_node = model.node_parents[@backingInt(case_node)] orelse return null; // safe: a node index indexes its own tree's parent table.
    const full = tree.fullSwitch(switch_node) orelse return null;
    var operand = try c.facts.resolve(capture.file, full.ast.condition);
    if (operand == .pointer) operand = operand.pointer.*;
    const container = switch (operand) {
        .instance, .container => |k| k,
        else => return null,
    };
    const member = c.facts.member(container, tree.tokenSlice(tree.nodeMainToken(item))) orelse return null;
    if (c.project.models[member.file.raw()].declarations[member.index].kind != .field) return null;
    return member;
}

/// The declared length of the fixed array a name holds, or points to (`var buf: [256]u8`,
/// `const t = [_]u8{ ... }`, a field `table: *const [256][4]u8`), its length a constant.
fn fixedLength(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Context.Error!?u128 {
    var decl = (try c.facts.definition(file, memory)) orelse return null;
    var record = c.project.models[decl.file.raw()].declarations[decl.index];
    // A prong's capture of a union's field (`.set => |s|`) has that field's type.
    if (record.kind == .capture) {
        decl = (try prongField(c, decl)) orelse return null;
        record = c.project.models[decl.file.raw()].declarations[decl.index];
    }
    const decl_tree = &c.project.files[decl.file.raw()].tree;
    const type_node: ?Ast.Node.Index = switch (record.kind) {
        .variable => blk: {
            const variable = decl_tree.fullVarDecl(record.node) orelse return null;
            if (variable.ast.type_node.unwrap()) |t| break :blk t;
            const init = variable.ast.init_node.unwrap() orelse return null;
            // What an allocator's `create(T)` makes points to one `T`.
            var call_buffer: [1]Ast.Node.Index = undefined;
            var made = init;
            if (decl_tree.nodeTag(made) == .@"try") made = decl_tree.nodeData(made).node;
            if (decl_tree.fullCall(&call_buffer, made)) |call| {
                if (call.ast.params.len != 1 or decl_tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
                if (!std.mem.eql(u8, decl_tree.tokenSlice(decl_tree.nodeData(call.ast.fn_expr).node_and_token[1]), "create")) return null;
                if (!try allocator(c, decl.file, decl_tree.nodeData(call.ast.fn_expr).node_and_token[0])) return null;
                break :blk call.ast.params[0];
            }
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
    var t = type_node orelse return null;
    // A pointer to one array (`*const [256][4]u8`) is indexed as the array is.
    if (decl_tree.fullPtrType(t)) |pointer| {
        if (pointer.size != .one) return null;
        t = pointer.ast.child_type;
    }
    if (decl_tree.nodeTag(t) != .array_type and decl_tree.nodeTag(t) != .array_type_sentinel) return null;
    const length_node = if (decl_tree.nodeTag(t) == .array_type) decl_tree.nodeData(t).node_and_node[0] else decl_tree.nodeData(t).node_and_extra[0];
    return (try valueOf(c, decl.file, length_node, 0)) orelse null;
}
