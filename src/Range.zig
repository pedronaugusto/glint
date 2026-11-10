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
const aegis = @import("aegis");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const File = @import("File.zig");
const Contract = @import("AegisContract.zig");
const Program = @import("Program.zig");
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
    pub fn room(self: Int) Magnitude {
        return filled(if (self.signed) self.bits -| 1 else self.bits);
    }

    /// The greatest magnitude a value of the type can have on some target.
    pub fn reach(self: Int) Magnitude {
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
        // The unsigned one's values and a sign: one bit more, which a `u65535` has no room for.
        const room = std.math.add(u16, unsigned.bits, 1) catch return .unknown;
        return .{ .int = .{ .bits = @max(signed.bits, room), .signed = true, .wide = if (wide) |w| @max(w, room) else null, .either = either } };
    }
};

/// The integer a magnitude is read in: wide enough for a type of 255 bits and a sum or product
/// past one, so a `u136` sum of two `u128` values is exact. A bound saturates at its greatest,
/// past every type's room (`atMost`).
pub const Magnitude = u256;

/// The pointer widths a range is read at: those of the targets the package builds for
/// (`Config.pointer_widths`), both 32 and 64 bits where it names none.
fn widths(c: *const Context) []const u16 {
    return if (c.config.pointer_widths.len == 0) &.{ 32, 64 } else c.config.pointer_widths;
}
/// How deep a reading follows constants' initializers.
const depth_limit = 12;
/// The most tokens a walk over one expression's tokens or parts takes: a file's default budget
/// for one expression (`File.Limits.expression_tokens`). A walk that reaches it gives the
/// answer that clears nothing.
const expression_tokens = @as(File.Limits, .{}).expression_tokens;

const accesses = Facts.accesses;
pub const Op = @FieldType(accesses.Operator, "op");

/// The form of the syntax `node` is (`Facts.accesses.formOf`).
pub fn formAt(tree: *const Ast, node: Ast.Node.Index) accesses.Form {
    return accesses.formOf(tree.nodeTag(node));
}

/// The operation `node` makes where it is an operator a past-range value stops (`a + b`, not
/// `a +% b`, `a +| b` or `a += b`); null for anything else.
pub fn checkedOp(tree: *const Ast, node: Ast.Node.Index) ?Op {
    if (formAt(tree, node) != .operator) return null;
    const operator = accesses.operatorOf(tree.nodeTag(node)) orelse return null;
    return if (operator.overflow == .checked) operator.op else null;
}

/// Whether `node` is the checked compound assignment of `op` (`a += b`, not `a +%= b`).
pub fn updates(tree: *const Ast, node: Ast.Node.Index, op: Op) bool {
    if (formAt(tree, node) != .compound_assign) return false;
    const operator = accesses.operatorOf(tree.nodeTag(node)) orelse return false;
    return operator.op == op and operator.overflow == .checked;
}

/// The reference `node` makes by its name, where it is a name a declaration may stand behind; an
/// enum literal the model also records is none (`Model.reference`).
pub fn nameRef(model: *const Model, node: Ast.Node.Index) ?Model.Reference {
    const reference = model.reference(node) orelse return null;
    return if (reference.unknown == .literal_context) null else reference;
}

/// Whether `node` is written as a name, where the model may index none (a prototype's own types,
/// `true`): a word on its own, not an enum literal's after its dot.
pub fn spellsName(tree: *const Ast, node: Ast.Node.Index) bool {
    if (formAt(tree, node) != .leaf) return false;
    const token = tree.nodeMainToken(node);
    return tree.tokenTag(token) == .identifier and (token == 0 or tree.tokenTag(token - 1) != .period);
}

/// Whether `node`, past parentheses and the conversions that keep a value, is an error value.
fn errorValue(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const written_here = (try c.facts.literalOf(file, bare(&c.project.at(file).file.tree, node))) orelse return false;
    return written_here == .error_value;
}

/// `x[a..]`: a slice with neither an end nor a sentinel. Null for anything else.
pub fn openSlice(tree: *const Ast, node: Ast.Node.Index) ?Ast.full.Slice {
    if (formAt(tree, node) != .slice) return null;
    const slice = tree.fullSlice(node) orelse return null;
    return if (slice.ast.end == .none and slice.ast.sentinel == .none) slice else null;
}

/// Whether a store's target is `_`, which discards: only a name can spell it.
pub fn discards(tree: *const Ast, target: Ast.Node.Index) bool {
    return formAt(tree, target) == .leaf and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_");
}

/// Whether arithmetic `node` (`+`, `*`, `-` and their assignments) cannot overflow its type
/// whatever its operands' ranges hold, at every pointer width, and an unsigned difference
/// cannot underflow.
pub fn fits(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    // Every path to it shows it within its type.
    const tree = &c.project.at(file).file.tree;
    const assigns = updates(tree, node, .add) or updates(tree, node, .sub) or updates(tree, node, .mul);
    const direct = checkedOp(tree, node);
    const multiplies = direct == .mul or updates(tree, node, .mul);
    const subtracts = direct == .sub or updates(tree, node, .sub);
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    for (widths(c)) |pointer| {
        const typed = if (assigns) try typeOf(c, file, lhs, pointer, 0) else try typeOf(c, file, node, pointer, 0);
        const int = switch (typed) {
            .int => |int| int,
            else => return false,
        };
        // A midpoint, `a + (b - a) / k`, is at most `b`: it fits where `b` does (the
        // difference's own underflow is judged where it is taken).
        if (direct == .add and midpoint(tree, lhs, rhs)) continue;
        // A remainder spelled out (`y - @divFloor(y, k) * k`) is below `k` and never below 0
        // where `y` is not.
        if (direct == .sub and try remainder(c, file, lhs, rhs) != null) continue;
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
            if (!subtracts and !multiplies) {
                if (try upper(c, file, lhs, node, pointer, 0)) |most| if (atMost(most +| k, int.room())) continue;
            }
        }
        const left = (try bound(c, file, lhs, pointer, 0)) orelse return false;
        const right = (try bound(c, file, rhs, pointer, 0)) orelse return false;
        const needed = if (multiplies) left *| right else left +| right;
        if (!atMost(needed, int.room())) return false;
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
        if (!atMost(magnitude, into.room())) return false;
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
    const declared_value = try c.facts.resolve(declared_file, declared);
    if (declared_value == .primitive and std.mem.eql(u8, declared_value.primitive, "bool")) return true;
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
fn upperByConstant(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, pointer: u16) Context.Error!?Magnitude {
    const tree = &c.project.at(file).file.tree;
    if (nameRef(&c.project.at(file).model, node) == null and formAt(tree, node) != .member) return null;
    var out: ?Magnitude = null;
    for (try facts(c, file, at)) |fact| {
        const base, const k = offset(tree, fact.small);
        if (!same(tree, base, node)) continue;
        const large = bare(tree, fact.large);
        const most: Magnitude = if (try valueOf(c, file, large, 0)) |value| value else most: {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, large) orelse continue;
            const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |d| d,
                .alternatives => continue,
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
    return bare(&c.project.at(file).file.tree, value);
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
fn bound(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?Magnitude {
    if (depth > depth_limit) return null;
    const own = try operation(c, file, node, pointer, depth);
    const typed: ?Magnitude = switch (try typeOf(c, file, node, pointer, depth)) {
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
fn upper(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?Magnitude {
    const tree = &c.project.at(file).file.tree;
    if (nameRef(&c.project.at(file).model, node) == null and formAt(tree, node) != .member) return null;
    var out: ?Magnitude = null;
    // A position the function indexes or slices memory with is below a length, and so is one
    // read below a length where it is used (a std search's in what it searched).
    if (try position(c, file, node)) out = length(pointer);
    const named_value = try alias(c, file, node);
    for (try gather(c, file, at)) |fact| {
        if (!fact.read) continue;
        const base, const k = offset(tree, fact.small);
        if (same(tree, base, node) or (named_value != null and same(tree, base, named_value.?))) out = narrower(out, length(pointer) -| k);
    }
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
const Assumed = struct { local: ?Model.Declaration.Id = null, skip: ?Ast.Node.Index = null };

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
    const tree = &c.project.at(file).file.tree;
    for (try facts(c, file, at)) |fact| {
        if (literal(tree, fact.small) != null and same(tree, fact.large, node)) return true;
    }
    // What an operation makes at zero or above: `@max(x, 0)`, `@mod(x, k)` by a positive `k`
    // (its sign is the divisor's), `x & mask` by a literal mask.
    const value = bare(tree, node);
    if (literal(tree, value) != null) return true;
    if (formAt(tree, value) == .operator) if (accesses.operatorOf(tree.nodeTag(value))) |operator| {
        const lhs, const rhs = tree.nodeData(value).node_and_node;
        switch (operator.op) {
            .bit_and => return literal(tree, lhs) != null or literal(tree, rhs) != null,
            .add, .mul => if (operator.overflow != .wrapping) return try nonnegativeIn(c, file, lhs, at, pointer, next, assumed) and try nonnegativeIn(c, file, rhs, at, pointer, next, assumed),
            .div => return (literal(tree, rhs) orelse 0) > 0 and try nonnegativeIn(c, file, lhs, at, pointer, next, assumed),
            else => {},
        }
    };
    if (formAt(tree, value) == .builtin) {
        const name = tree.tokenSlice(tree.nodeMainToken(value));
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, value, &buffer);
        // Two operands at most: more is no builtin this reads.
        if (args.len > 2) return false;
        if (std.mem.eql(u8, name, "@abs")) return true;
        // A count of bits, or a bool's 0 or 1.
        for ([_][]const u8{ "@ctz", "@clz", "@popCount", "@intFromBool" }) |count| if (std.mem.eql(u8, name, count)) return true;
        if (args.len == 1 and std.mem.eql(u8, name, "@intCast")) return nonnegativeIn(c, file, args[0], at, pointer, next, assumed);
        if (args.len != 2) return false;
        if (std.mem.eql(u8, name, "@as")) return nonnegativeIn(c, file, args[1], at, pointer, next, assumed);
        if (std.mem.eql(u8, name, "@max")) return literal(tree, args[0]) != null or literal(tree, args[1]) != null;
        if (std.mem.eql(u8, name, "@mod")) return (literal(tree, args[1]) orelse 0) > 0;
        if (std.mem.eql(u8, name, "@rem")) return (literal(tree, args[1]) orelse 0) > 0 and try nonnegativeIn(c, file, args[0], at, pointer, next, assumed);
        if (std.mem.eql(u8, name, "@divTrunc") or std.mem.eql(u8, name, "@divFloor")) return (literal(tree, args[1]) orelse 0) > 0 and try nonnegativeIn(c, file, args[0], at, pointer, next, assumed);
        return false;
    }
    const model = &c.project.at(file).model;
    const named_here = nameRef(model, value) orelse return false;
    const d = named_here.declaration orelse return false;
    if (assumed.local == d) return true;
    const record = model.declarations[@backingInt(d)];
    if (record.kind != .variable) return false;
    const variable = tree.fullVarDecl(record.node) orelse return false;
    const init = variable.ast.init_node.unwrap() orelse return false;
    if (tree.tokenTag(variable.ast.mut_token) == .keyword_const or try kept(c, file, value, record.node, at)) return nonnegativeIn(c, file, init, init, pointer, next, assumed);
    // A variable every value of which is at zero or above: its initializer and what each
    // assignment gives it, its own reads in them taken as such.
    if (assumed.local != null) return false;
    const inductive: Assumed = .{ .local = d, .skip = assumed.skip };
    if (!try nonnegativeIn(c, file, init, init, pointer, next, inductive)) return false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const assignment: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const form = accesses.formOf(tag);
        if (form != .assign and form != .compound_assign) continue;
        const target, const given = tree.nodeData(assignment).node_and_node;
        if (accesses.operatorOf(tag)) |operator| {
            // A sum or product of what is at zero or above is; any other update may not be.
            if ((operator.op != .add and operator.op != .mul) or operator.overflow == .wrapping) {
                if (nameRef(model, target)) |r| if (r.declaration == d) return false;
                continue;
            }
        }
        const ref = nameRef(model, target) orelse continue;
        if (ref.declaration != d) continue;
        if (assumed.skip == assignment) continue;
        if (!try nonnegativeIn(c, file, given, given, pointer, next, inductive)) return false;
    }
    // Any other write is none the induction reads: its address handed on lets a callee write it,
    // and a destructuring or an `asm` output writes it directly.
    return !try written(c, file, d);
}

/// Whether a local is written other than by an assignment to its name: by another name
/// (`addressed`), or by a destructure naming it.
fn written(c: *Context, file: Project.FileId, d: Model.Declaration.Id) Context.Error!bool {
    if (try addressed(c, file, d)) return true;
    const tree = &c.project.at(file).file.tree;
    var in_file: [1]Project.FileId = undefined;
    var found_sites = try declarationWrites(c, file, d, &in_file);
    while (try found_sites.next()) |site| if (formAt(tree, site.node) == .destructure) return true;
    return false;
}

/// The writes `Facts.accesses` finds of a declaration: in its file for a function's own, in
/// every file of the program's for one outside any function.
/// `in_file` holds the one file a function's own is read in.
fn declarationWrites(c: *Context, file: Project.FileId, d: Model.Declaration.Id, in_file: *[1]Project.FileId) Context.Error!Facts.accesses.Each {
    const model = &c.project.at(file).model;
    in_file.* = .{file};
    const files: []const Project.FileId = switch (model.scopes[@backingInt(model.declarations[@backingInt(d)].scope)].kind) {
        .file, .container => try programFiles(c),
        else => in_file,
    };
    return Facts.accesses.writes(c.facts, .{ .declaration = .{ .file = file, .index = d } }, files);
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
    const tree = &c.project.at(file).file.tree;
    return pointerValue(c, file, tree.nodeData(node).node_and_node[0], 0);
}

/// Whether pointer arithmetic stays within the memory its pointer came from, and so does what
/// is read through it: `x.ptr + o` with `o` below the length of `x` leaves `x.len - o` bytes, at
/// least one, so a read of its first element (`(x.ptr + o)[0]`, `[0..1]`) is within. Any other
/// read, or the moved pointer kept or given on, reaches past what the comparison shows. Only a
/// pointer moved forward is: `x.ptr - o` reaches before the memory whatever `o` is below.
pub fn movedWithin(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    if (tree.nodeTag(node) != .add) return false;
    const base, const moved = tree.nodeData(node).node_and_node;
    const at = bare(tree, base);
    // A slice's own `ptr`, by the holder's type (`Facts.languageField`).
    if (try c.facts.languageField(file, at) != .ptr) return false;
    const memory = tree.nodeData(at).node_and_token[0];
    if (!firstRead(c, file, node)) return false;
    return within(c, file, moved, memory, false);
}

/// Whether a moved pointer is read only at its first element, where it is computed.
fn firstRead(c: *Context, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    var parent = model.parentOf(at) orelse return false;
    while (formAt(tree, parent) == .grouped) {
        at = parent;
        parent = model.parentOf(at) orelse return false;
    }
    if (formAt(tree, parent) == .array_access) {
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
    // Past so many constants, what it is is unknown: read as an address, which the input
    // that moves it is judged by.
    if (depth > 4) return true;
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, node);
    switch (try c.facts.resolve(file, at)) {
        .pointer => return true,
        // A choice is judged by its arithmetic and constants below, as no one pointer.
        .alternatives => {},
        else => {},
    }
    if (formAt(tree, at) == .operator) if (accesses.operatorOf(tree.nodeTag(at))) |operator| {
        // An address moved: by a sum or a difference that may wrap, never one that saturates.
        if ((operator.op == .add or operator.op == .sub) and operator.overflow != .saturating) return pointerValue(c, file, tree.nodeData(at).node_and_node[0], depth + 1);
        return false;
    };
    if (Facts.isBuiltin(tree, at, "@intFromPtr")) return true;
    const local = constantOf(c, file, at) orelse return false;
    return pointerValue(c, file, local.ast.init_node.unwrap() orelse return false, depth + 1);
}

/// What an expression's own operation bounds, before its type does.
fn operation(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?Magnitude {
    const tree = &c.project.at(file).file.tree;
    const next = depth + 1;
    switch (formAt(tree, node)) {
        .leaf => {
            if (try c.facts.literalOf(file, node)) |written_here| switch (written_here) {
                .number => return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
                    .int => |value| value,
                    else => null,
                },
                .char => return literal(tree, node) orelse 0x10ffff,
                else => return null,
            };
            const model = &c.project.at(file).model;
            const ref = nameRef(model, node) orelse return null;
            const d = ref.declaration orelse return null;
            if (prong(c, .{ .file = file, .index = d })) |range| return range.most;
            return constant(c, .{ .file = file, .index = d }, pointer, next);
        },
        .member => {
            // A length of memory the program holds: below half the address space where its
            // elements take room.
            switch (try c.facts.memoryField(file, node)) {
                .memory => return if (try lengthWritten(c, file, tree.nodeData(node).node_and_token[0])) filled(pointer) else length(pointer),
                .unsized => return filled(pointer),
                .field => {},
            }
            const decl = ((try c.facts.definition(file, node)).orNull()) orelse return chosen(c, file, node, pointer, next);
            return constant(c, decl, pointer, next);
        },
        .grouped, .unwrap_optional => return bound(c, file, tree.nodeData(node).node_and_token[0], pointer, next),
        .tried => return bound(c, file, tree.nodeData(node).node, pointer, next),
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            // A fallback that leaves (`orelse return error.Short`) gives no value.
            if (leaves(tree, rhs)) return bound(c, file, lhs, pointer, next);
            return wider(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next));
        },
        .compound_assign => {
            if (!updates(tree, node, .add)) return null;
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return sum(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next));
        },
        .operator => return operatorBound(c, file, node, pointer, next),
        .@"if" => {
            const branch = tree.fullIf(node).?;
            const then = try bound(c, file, branch.ast.then_expr, pointer, next);
            const otherwise = branch.ast.else_expr.unwrap() orelse return then;
            return wider(then, try bound(c, file, otherwise, pointer, next));
        },
        .@"switch" => {
            var out: ?Magnitude = 0;
            for (tree.fullSwitch(node).?.ast.cases) |case| {
                const full = tree.fullSwitchCase(case) orelse return null;
                out = wider(out, try bound(c, file, full.ast.target_expr, pointer, next));
            }
            return out;
        },
        .builtin => return builtin(c, file, node, pointer, next),
        .call => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?; // unreachable: a call's form holds calls
            return switch (try c.facts.resolve(file, call.ast.fn_expr)) {
                .function => |decl| (try extreme(c, file, decl, call, pointer)) orelse (try readCount(c, file, decl, call)) orelse returned(c, decl, pointer),
                // A choice of functions bounds nothing here: not known.
                .alternatives => null,
                else => null,
            };
        },
        else => return null,
    }
}

/// What an operator bounds: a negation its operand's magnitude, checked arithmetic by what it
/// does to its operands' bounds. Wrapping, saturating or `~` read as nothing shown here.
fn operatorBound(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, next: u8) Context.Error!?Magnitude {
    const tree = &c.project.at(file).file.tree;
    if (accesses.unaryOf(tree.nodeTag(node)) == .negation) return bound(c, file, tree.nodeData(node).node, pointer, next);
    const op = checkedOp(tree, node) orelse return null;
    const lhs, const rhs = tree.nodeData(node).node_and_node;
    switch (op) {
        .add => return sum(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next)),
        .sub => {
            const signed = switch (try typeOf(c, file, node, pointer, next)) {
                .int => |int| int.signed,
                else => return null,
            };
            // What is left of a value once its quotient by `k` is taken away (`y -
            // @divFloor(y, k) * k`) is a remainder, below `k`.
            if (try remainder(c, file, lhs, rhs)) |k| return ((try bound(c, file, k, pointer, next)) orelse return null) -| 1;
            // An unsigned difference that does not underflow is at most what it takes
            // from, less a constant it takes (an underflow stops the program: A010's to
            // judge).
            if (!signed) return ((try bound(c, file, lhs, pointer, next)) orelse return null) -| (literal(tree, rhs) orelse 0);
            return sum(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next));
        },
        .mul => {
            const left = (try bound(c, file, lhs, pointer, next)) orelse return null;
            const right = (try bound(c, file, rhs, pointer, next)) orelse return null;
            return left *| right;
        },
        .div => return quotient(try bound(c, file, lhs, pointer, next), literal(tree, rhs)),
        .mod => return ((try bound(c, file, rhs, pointer, next)) orelse return null) -| 1,
        // A shift by at most `k` moves at most as far as one by `k`.
        .shl => {
            const by = literal(tree, rhs) orelse std.math.cast(u64, (try bound(c, file, rhs, pointer, next)) orelse return null) orelse return null;
            return shifted(try bound(c, file, lhs, pointer, next), by);
        },
        .shr => {
            const left = (try bound(c, file, lhs, pointer, next)) orelse return null;
            const by = literal(tree, rhs) orelse return left;
            return if (by >= @bitSizeOf(Magnitude)) 0 else left >> @intCast(by);
        },
        .bit_and => {
            const left = try bound(c, file, lhs, pointer, next);
            const right = try bound(c, file, rhs, pointer, next);
            if (left == null) return right;
            if (right == null) return left;
            return @min(left.?, right.?);
        },
        .bit_or, .bit_xor => {
            const most = wider(try bound(c, file, lhs, pointer, next), try bound(c, file, rhs, pointer, next)) orelse return null;
            return filled(std.math.sub(u16, @bitSizeOf(Magnitude), @clz(most)) catch return null);
        },
        else => return null,
    }
}

/// `std.math.maxInt(T)` of an integer type `T`: its greatest value, so a guard `x <=
/// std.math.maxInt(u32)` bounds `x` as a literal would.
fn extreme(c: *Context, file: Project.FileId, decl: Facts.Decl, call: Ast.full.Call, pointer: u16) Context.Error!?Magnitude {
    if (call.ast.params.len != 1) return null;
    for (((try Governed.declarations(c, "std", "math.maxInt")).orNull()) orelse return null) |each| {
        if (each.file != decl.file or each.index != decl.index) continue;
        const int = (try named(c, file, call.ast.params[0], pointer)) orelse return null;
        if (int.bits == 0) return 0;
        return int.reach();
    }
    return null;
}

/// The count std's `Io.Reader.readSliceShort` returns: at most its buffer's length, where the
/// buffer is an array of a length the program fixes (`&buf`, or a pointer to one).
fn readCount(c: *Context, file: Project.FileId, decl: Facts.Decl, call: Ast.full.Call) Context.Error!?Magnitude {
    if (call.ast.params.len == 0) return null;
    for (((try Governed.declarations(c, "std", "Io.Reader.readSliceShort")).orNull()) orelse return null) |each| {
        if (each.file != decl.file or each.index != decl.index) continue;
        const tree = &c.project.at(file).file.tree;
        var buffer = bare(tree, call.ast.params[call.ast.params.len - 1]);
        if (formAt(tree, buffer) == .address_of) buffer = bare(tree, tree.nodeData(buffer).node);
        return fixedLength(c, file, buffer);
    }
    return null;
}

/// What a function of the program returns at most, read once per function and pointer width:
/// the widest of its `return`s, each read in its body.
const Returns = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, ?Magnitude) = .empty };

fn returned(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!?Magnitude {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Returns);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A function that reaches itself is read as unbounded while it is being read.
    try memo.map.put(c.allocator, key, null);
    // The program's functions are read; std's and aegis's are known by their declarations.
    if (!try Program.owns(c, decl.file)) return null;
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    // A function is declared at its prototype; its body is the declaration around it.
    const function = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse return null;
    if (tree.nodeTag(function) != .fn_decl) return null;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var out: ?Magnitude = 0;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last or enclosing(tree, model, node) != function) continue;
        const value = tree.nodeData(node).opt_node.unwrap() orelse continue;
        // Read from its own body, at no depth: what is kept answers every caller, so it is
        // never what the first one's depth left of it. A chain of calls ends at the memo (a
        // function being read is unbounded), each function read once.
        out = wider(out, try bound(c, decl.file, value, pointer, 0));
        if (out == null) break;
    }
    try memo.map.put(c.allocator, key, out);
    return out;
}

/// The function a node is in.
fn enclosing(tree: *const Ast, model: anytype, node: Ast.Node.Index) ?Ast.Node.Index {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return parent;
    }
    return null;
}

/// What a builtin's operation bounds.
fn builtin(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?Magnitude {
    const tree = &c.project.at(file).file.tree;
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
        return if (by >= @bitSizeOf(Magnitude)) 0 else (left orelse return null) >> @intCast(by);
    }
    return null;
}

/// What a declaration's value is bounded by: a constant's by its initializer (and its type,
/// where it spells one); a function's local variable by every value it is given; a
/// parameter, a field or a capture by its type alone.
/// A member of a per-build choice of types (`Hash.digest_length`, `Hash` one of a suite's
/// hashers by an `inline else` prong): the widest of what each alternative's member holds at
/// most, and nothing where one alternative is no container or lacks it.
fn chosen(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?Magnitude {
    const tree = &c.project.at(file).file.tree;
    const holder, const name = tree.nodeData(node).node_and_token;
    const value = try c.facts.resolve(file, holder);
    if (value != .alternatives) return null;
    const member = try Model.identifier(c.allocator, tree.tokenSlice(name));
    var out: Magnitude = 0;
    for (value.alternatives) |one| {
        if (one != .container) return null;
        const decl = c.facts.member(one.container, member) orelse return null;
        const most: ?Magnitude = if (one.container.made_by) |made| (if (try madeConstant(c, decl, made)) |k| k else null) else try constant(c, decl, pointer, depth);
        out = @max(out, most orelse return null);
    }
    return out;
}

/// A constant of a container a type function made: its initializer read with the function's
/// parameters bound to the arguments of the call that made it (`digest_bits / 8` in
/// `Sha2x32(iv256, 256)`).
fn madeConstant(c: *Context, decl: Facts.Decl, made: *const Facts.Made) Context.Error!?u64 {
    const tree = &c.project.at(decl.file).file.tree;
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .variable) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return madeValue(c, decl.file, variable.ast.init_node.unwrap() orelse return null, made, 0);
}

fn madeValue(c: *Context, file: Project.FileId, node: Ast.Node.Index, made: *const Facts.Made, depth: u8) Context.Error!?u64 {
    if (depth > 4) return null;
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, node);
    if (literal(tree, at)) |k| return k;
    if (checkedOp(tree, at)) |op| {
        if (op != .add and op != .sub and op != .mul and op != .div) return null;
        const lhs, const rhs = tree.nodeData(at).node_and_node;
        const a = (try madeValue(c, file, lhs, made, depth + 1)) orelse return null;
        const b = (try madeValue(c, file, rhs, made, depth + 1)) orelse return null;
        return switch (op) {
            .add => std.math.add(u64, a, b) catch null,
            .sub => std.math.sub(u64, a, b) catch null,
            .mul => std.math.mul(u64, a, b) catch null,
            else => if (b == 0) null else a / b,
        };
    }
    if (formAt(tree, at) == .builtin) {
        const name = tree.tokenSlice(tree.nodeMainToken(at));
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, at, &buffer);
        if (args.len != 2) return null;
        const a = (try madeValue(c, file, args[0], made, depth + 1)) orelse return null;
        const b = (try madeValue(c, file, args[1], made, depth + 1)) orelse return null;
        if (b == 0) return null;
        if (std.mem.eql(u8, name, "@divFloor") or std.mem.eql(u8, name, "@divTrunc")) return a / b;
        if (std.mem.eql(u8, name, "@divCeil")) return std.math.divCeil(u64, a, b) catch null;
        if (std.mem.eql(u8, name, "@divExact")) return if (a % b == 0) a / b else null;
        return null;
    }
    const model = &c.project.at(file).model;
    const d = (nameRef(model, at) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    switch (record.kind) {
        .parameter => {
            const given = (try madeArgument(c, .{ .file = file, .index = d }, made)) orelse return null;
            return valueOf(c, made.file, given, depth + 1);
        },
        .variable => return madeConstant(c, .{ .file = file, .index = d }, made),
        else => return null,
    }
}

/// The argument the call that made a container gives the type function's parameter `decl`,
/// where `decl` is one of that function's parameters.
fn madeArgument(c: *Context, decl: Facts.Decl, made: *const Facts.Made) Context.Error!?Ast.Node.Index {
    if (decl.file != made.function.file) return null;
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    const token = model.declarations[@backingInt(decl.index)].token;
    const function = model.declarations[@backingInt(made.function.index)].node;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, function) orelse return null;
    var it = proto.iterate(tree);
    var index: usize = 0;
    const at = while (it.next()) |param| : (index += 1) {
        if (param.name_token == token) break index;
    } else return null;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = c.project.at(made.file).file.tree.fullCall(&call_buffer, made.call) orelse return null;
    return if (at < call.ast.params.len) call.ast.params[at] else null;
}

fn constant(c: *Context, decl: Facts.Decl, pointer: u16, depth: u8) Context.Error!?Magnitude {
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    const record = model.declarations[@backingInt(decl.index)];
    if (record.kind == .field) return stored(c, decl, pointer);
    if (record.kind != .variable) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return assigned(c, decl, pointer);
    const init = variable.ast.init_node.unwrap() orelse return null;
    return bound(c, decl.file, init, pointer, depth);
}

/// What a function's local variable holds at most, read once per variable and pointer width:
/// the widest of its initializer and of each value assigned to it, every one read where it is
/// given (`null` and `undefined` give none). One added to, multiplied or shifted in place, or
/// whose address is taken, is unknown.
const Assigned = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, ?Magnitude) = .empty };

fn assigned(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!?Magnitude {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Assigned);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A variable given a value that reads itself is unknown while it is being read.
    try memo.map.put(c.allocator, key, null);
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    // Written by another name (`addressed`).
    if (try addressed(c, decl.file, decl.index)) return null;
    _ = enclosing(tree, model, model.declarations[@backingInt(decl.index)].node) orelse return null;
    var out: ?Magnitude = 0;
    var in_file: [1]Project.FileId = undefined;
    var found_sites = try declarationWrites(c, decl.file, decl.index, &in_file);
    while (try found_sites.next()) |site| {
        if (out == null) break;
        switch (site.kind) {
            // Its initializer, `x = v`, a destructure's element: what each gives. A destructure
            // of anything but a literal gives no one value.
            .init, .set => {
                const value = site.value orelse {
                    out = null;
                    continue;
                };
                // Read where it is given, at no depth: what is kept answers every reader (`returned`).
                if (!try empty(c, decl.file, value)) out = wider(out, try bound(c, decl.file, value, pointer, 0));
            },
            .update, .covered, .address, .open => out = null,
            .read => {},
        }
    }
    try memo.map.put(c.allocator, key, out);
    return out;
}

/// The containers a type given as a call's argument names, found once for the run: a function
/// may fill a type it is given by reflection (`std.json` parsing a `Config`, `bytesToValue(Header,
/// …)`), and with it every container the type holds, so their fields have values no store sets.
/// Each argument is read by what it resolves to, however it is spelled (an alias, `@TypeOf(x)`,
/// `@call`'s tuple).
const Given = struct {
    built: bool = false,
    /// Each container so given, by identity.
    shapes: std.AutoHashMapUnmanaged(struct { Project.FileId, Model.Scope.Id }, void) = .empty,
    /// Whether an argument that may be a type does not resolve: it may be any container.
    any: bool = false,
};

fn givenTypes(c: *Context) Context.Error!*Given {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Given);
    if (memo.built) return memo;
    memo.built = true;
    for (c.project.sources) |*source| {
        const file = source.id;
        if (!try Program.owns(c, file)) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var call_buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullCall(&call_buffer, node)) |call| {
                for (call.ast.params, 0..) |arg, k| try typeArgument(c, memo, file, call.ast.fn_expr, k, arg);
                continue;
            }
            if (accesses.formOf(tag) != .builtin) continue;
            // `@call(modifier, f, .{ … })` calls `f` with the tuple's elements.
            if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@call")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, node, &buffer);
            if (args.len != 3) continue;
            var tuple_buffer: [2]Ast.Node.Index = undefined;
            const tuple = tree.fullArrayInit(&tuple_buffer, args[2]) orelse {
                memo.any = true;
                continue;
            };
            for (tuple.ast.elements, 0..) |arg, k| try typeArgument(c, memo, file, args[1], k, arg);
        }
    }
    return memo;
}

/// Records what the argument at `position` of a call of `callee` gives as a type.
fn typeArgument(c: *Context, memo: *Given, file: Project.FileId, callee: Ast.Node.Index, at: usize, arg: Ast.Node.Index) Context.Error!void {
    // A parameter declared of a type other than `type` or `anytype` takes no type: what is
    // given there is not read at all.
    if (Facts.accesses.inert(&c.project.at(file).file.tree, arg) or !try takesType(c, file, callee, at)) return;
    const value = try c.facts.resolve(file, arg);
    switch (value) {
        .container, .alternatives, .reified => return typeShapes(c, memo, value, 0),
        .unknown => |why| switch (why) {
            .zig_own, .absent => return,
            else => {},
        },
        // A value is no type: one handed over by a pointer is a write `Facts.accesses` finds.
        else => return,
    }
    // A parameter of a function of the program's is given by its calls, whose arguments are
    // read where they are.
    const model = &c.project.at(file).model;
    if (nameRef(model, arg)) |ref| if (ref.declaration) |d| {
        if (model.declarations[@backingInt(d)].kind == .parameter) return;
    };
    memo.any = true;
}

/// Whether a call of `callee` may take a type at `position`: unless it resolves to a function
/// whose parameter there is declared of a type that is not `type`.
fn takesType(c: *Context, file: Project.FileId, callee: Ast.Node.Index, at: usize) Context.Error!bool {
    const function = switch (try c.facts.resolve(file, callee)) {
        .function => |f| f,
        // A choice of functions may take one.
        .alternatives => return true,
        else => return true,
    };
    const tree = &c.project.at(function.file).file.tree;
    const record = c.project.at(function.file).model.declarations[@backingInt(function.index)];
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, switch (tree.nodeTag(record.node)) {
        .fn_decl => tree.nodeData(record.node).node_and_node[0],
        else => record.node,
    }) orelse return true;
    // A method called on a value is given its receiver first: the call is read in its own file.
    const at_call = &c.project.at(file).file.tree;
    const bound_receiver = formAt(at_call, callee) == .member and switch (try c.facts.resolve(file, at_call.nodeData(callee).node_and_token[0])) {
        .container => false,
        // A choice may or may not hand a receiver first: its position is not known.
        .alternatives => return true,
        else => true,
    };
    var params = proto.iterate(tree);
    var k: usize = 0;
    while (params.next()) |param| : (k += 1) {
        if (k != at + @intFromBool(bound_receiver)) continue;
        const kind = param.type_expr orelse return true;
        // A parameter's type that does not resolve may be `type`.
        return switch (try c.facts.resolve(function.file, kind)) {
            .primitive => |name| std.mem.eql(u8, name, "type"),
            .unknown, .alternatives => true,
            else => false,
        };
    }
    // A variadic `extern`'s or one past the list: nothing known.
    return true;
}

/// Marks the containers a type is, and those its fields hold, by value or through pointers.
fn typeShapes(c: *Context, memo: *Given, value: Facts.Value, depth: u8) Context.Error!void {
    if (depth >= 16) {
        memo.any = true;
        return;
    }
    switch (value) {
        .container => |k| {
            if ((try memo.shapes.getOrPut(c.allocator, .{ k.file, k.scope })).found_existing) return;
            const model = &c.project.at(k.file).model;
            for (model.declarations, 0..) |record, d| {
                if (record.kind != .field or record.scope != k.scope) continue;
                try typeShapes(c, memo, try c.facts.memberOf(k, .{ .file = k.file, .index = @fromBackingInt(@intCast(d)) }), depth + 1);
            }
        },
        // A field's type reads as a value of it.
        .instance => |k| try typeShapes(c, memo, .{ .container = k }, depth),
        .pointer => |inner| try typeShapes(c, memo, inner.child.*, depth + 1),
        .optional, .array, .error_union => |inner| try typeShapes(c, memo, inner.*, depth + 1),
        .alternatives => |each| for (each) |one| try typeShapes(c, memo, one, depth + 1),
        .reified => memo.any = true,
        // A field whose type does not resolve may hold any container, but for what Zig itself
        // declares or a name the program does not have.
        .unknown => |why| switch (why) {
            .zig_own, .absent => {},
            else => memo.any = true,
        },
        else => {},
    }
}

/// The program's own files, the ones whose stores a field's invariant reads.
pub fn programFiles(c: *Context) Context.Error![]const Project.FileId {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const Files = struct { built: bool = false, list: std.ArrayList(Project.FileId) = .empty };
    const memo = try c.facts.memo(Files);
    if (memo.built) return memo.list.items;
    memo.built = true;
    for (c.project.sources) |*source| if (try Program.owns(c, source.id)) try memo.list.append(c.allocator, source.id);
    return memo.list.items;
}

/// What a field of a plain struct holds at most, read once per field and pointer width: the
/// widest of its default and of every value the program's own files store in it, each read
/// where it is stored. One changed in place or whose address is taken is unknown, and so is a
/// field of an `extern` or `packed` struct, whose bytes a reinterpretation sets with no store.
const Stored = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, u16 }, ?Magnitude) = .empty };

/// Whether every write of a field is a store the program's own files show: a field of a plain
/// struct of the program's (std and aegis set theirs) that no write `Facts.accesses` finds
/// covers (a cast, a byte view, a pointer handed to code the program does not hold, `asm`) or
/// names as the program compiles (`@field(x, name)`), and no type a call is given holds, which
/// it may fill by reflection.
pub fn storesShown(c: *Context, decl: Facts.Decl) Context.Error!bool {
    if (!try Program.owns(c, decl.file)) return false;
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    const record = model.declarations[@backingInt(decl.index)];
    _ = model.containerField(tree, record.node) orelse return false;
    const container_node = model.scopes[@backingInt(record.scope)].node;
    // A file's own fields are an auto-layout struct's, as Zig reads every file.
    if (container_node != .root) {
        var buffer: [2]Ast.Node.Index = undefined;
        const holder = tree.fullContainerDecl(&buffer, container_node) orelse return false;
        if (holder.layout_token != null or tree.tokenTag(holder.ast.main_token) != .keyword_struct) return false;
    }
    const given = try givenTypes(c);
    if (given.any or given.shapes.contains(.{ decl.file, record.scope })) return false;
    var found_sites = Facts.accesses.writes(c.facts, .{ .field = decl }, try programFiles(c));
    while (try found_sites.next()) |site| {
        if (site.kind == .covered or site.kind == .open or site.computed) return false;
    }
    return true;
}

/// Whether a field changes only by stores through its name (`x.field = v`, `x.field += v`): its
/// writes are all shown (`storesShown`) and its address is never taken, so no pointer reaches it.
pub fn placeable(c: *Context, decl: Facts.Decl) Context.Error!bool {
    if (!try storesShown(c, decl)) return false;
    var found_sites = Facts.accesses.writes(c.facts, .{ .field = decl }, try programFiles(c));
    while (try found_sites.next()) |site| {
        if (site.kind == .address and (site.reach == .exact or site.reach == .named)) return false;
    }
    return true;
}

/// Whether an optional field is null or not only by stores through its name: its writes are
/// all shown (`storesShown`) and no pointer to the optional itself is taken (`&x.field`). A
/// pointer to its payload (`&x.field.?`, `if (x.field) |*p|`) writes the payload, never whether
/// there is one (Bounds' presence).
pub fn presenceable(c: *Context, decl: Facts.Decl) Context.Error!bool {
    if (!try storesShown(c, decl)) return false;
    var found_sites = Facts.accesses.writes(c.facts, .{ .field = decl }, try programFiles(c));
    while (try found_sites.next()) |site| {
        if (site.kind != .address or site.part) continue;
        const tree = &c.project.at(site.file).file.tree;
        // The capture of a branch or a loop over the optional points to its payload.
        if (Facts.accesses.formOf(tree.nodeTag(site.node)) == .address_of) return false;
    }
    return true;
}

fn stored(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!?Magnitude {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Stored);
    const key = .{ decl, pointer };
    if (memo.map.get(key)) |known| return known;
    // A field given a value that reads itself is unknown while it is being read.
    try memo.map.put(c.allocator, key, null);
    if (!try storesShown(c, decl)) return null;
    var out: ?Magnitude = 0;
    var found_sites = Facts.accesses.writes(c.facts, .{ .field = decl }, try programFiles(c));
    while (try found_sites.next()) |site| {
        if (out == null) break;
        switch (site.kind) {
            .init, .set => {
                // A field's default, a literal's value for it, a store: what it gives. A store
                // with no one value (a destructure of a call's result, a copy into its memory)
                // is unknown.
                const value = site.value orelse {
                    out = null;
                    continue;
                };
                // A whole value of the struct (`s = t`, or one that holds it) carries what the
                // stores that made it gave the field.
                if (site.reach == .holder or site.reach == .unresolved) if (wholeValue(try c.facts.resolve(site.file, value))) continue;
                // Read where it is stored, at no depth: what is kept answers every reader (`returned`).
                if (!try empty(c, site.file, value)) out = wider(out, try bound(c, site.file, value, pointer, 0));
            },
            .update, .covered, .open => out = null,
            // A pointer to the field writes it wherever it goes; one to a whole value writes
            // the field by a member store, which is a site of its own.
            .address => if (site.reach == .exact or site.reach == .named) {
                out = null;
            },
            .read => {},
        }
    }
    try memo.map.put(c.allocator, key, out);
    return out;
}

/// Whether a value is a container's instance, or an optional, error union or array of one; or
/// a struct literal with no type of its own, whose fields' values are sites of their own.
fn wholeValue(value: Facts.Value) bool {
    var current = value;
    while (true) current = switch (current) {
        .optional, .error_union, .array => |inner| inner.*,
        .instance, .literal => return true,
        .alternatives => |each| {
            for (each) |one| if (!wholeValue(one)) return false;
            return true;
        },
        else => return false,
    };
}

/// Whether a value is `null` or `undefined`: no number.
fn empty(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const written_here = (try c.facts.literalOf(file, node)) orelse return false;
    return written_here == .null or written_here == .undefined;
}

/// The integer type `node` computes in.
fn typeOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!Typed {
    if (depth > depth_limit) return .unknown;
    const tree = &c.project.at(file).file.tree;
    const next = depth + 1;
    switch (formAt(tree, node)) {
        .grouped, .unwrap_optional => return typeOf(c, file, tree.nodeData(node).node_and_token[0], pointer, next),
        .tried => return typeOf(c, file, tree.nodeData(node).node, pointer, next),
        .operator => {
            if (accesses.unaryOf(tree.nodeTag(node))) |unary| {
                if (unary != .negation_wrap) return typeOf(c, file, tree.nodeData(node).node, pointer, next);
            } else {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                const operator = accesses.operatorOf(tree.nodeTag(node)).?; // unreachable: an operator on two is `operatorOf`'s
                if (operator.op == .shl or operator.op == .shr) return typeOf(c, file, lhs, pointer, next);
                return Typed.peer(try typeOf(c, file, lhs, pointer, next), try typeOf(c, file, rhs, pointer, next));
            }
        },
        .@"orelse", .@"catch" => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            // A fallback that leaves gives no value: the type is the unwrapped one's.
            if (leaves(tree, rhs)) return typeOf(c, file, lhs, pointer, next);
            return Typed.peer(try typeOf(c, file, lhs, pointer, next), try typeOf(c, file, rhs, pointer, next));
        },
        .@"if" => {
            const branch = tree.fullIf(node).?;
            const then = try typeOf(c, file, branch.ast.then_expr, pointer, next);
            const otherwise = branch.ast.else_expr.unwrap() orelse return then;
            return Typed.peer(then, try typeOf(c, file, otherwise, pointer, next));
        },
        .builtin => {
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
            if ((std.mem.eql(u8, name, "@min") or std.mem.eql(u8, name, "@max")) and args.len >= 2) return minMaxType(c, file, args, std.mem.eql(u8, name, "@min"), pointer, next);
            for ([_][]const u8{ "@divFloor", "@divTrunc", "@divExact", "@mod", "@rem" }) |peer| if (std.mem.eql(u8, name, peer) and args.len == 2) {
                return Typed.peer(try typeOf(c, file, args[0], pointer, next), try typeOf(c, file, args[1], pointer, next));
            };
        },
        .leaf, .member => {
            if (try c.facts.literalOf(file, node)) |written_here| if (written_here == .number or written_here == .char) return .literal;
            const ref = nameRef(&c.project.at(file).model, node);
            if (ref != null or formAt(tree, node) == .member) {
                if (try c.facts.memoryField(file, node) != .field) return .{ .int = .{ .bits = pointer, .signed = false } };
                const decl = ((try c.facts.definition(file, node)).orNull()) orelse if (ref) |named_ref| (if (named_ref.declaration) |d| Facts.Decl{ .file = file, .index = d } else null) else null;
                // A constant with no type of its own has its initializer's: a number literal's
                // comptime type, which takes the other operand's.
                if (decl) |d| {
                    if (try untyped(c, d)) |init| return typeOf(c, d.file, init, pointer, next);
                    // A variable with no type of its own has its initializer's, which no
                    // assignment changes (`var i = at + 1` is a `usize` where `at` is): a runtime
                    // one, as Zig takes no comptime number for a `var`.
                    if (try inferred(c, d)) |init| switch (try typeOf(c, d.file, init, pointer, next)) {
                        .int => |int| return .{ .int = int },
                        else => {},
                    };
                    if (try element(c, d, pointer)) |typed| return typed;
                }
            }
        },
        else => {},
    }
    return integer(try c.facts.resolve(file, node), pointer);
}

/// The type of a `for` capture taking an element of memory (`for (bytes) |b|` over a
/// `[]const u8` is a `u8`), or of a range's index (`usize`); null for anything else.
fn element(c: *Context, decl: Facts.Decl, pointer: u16) Context.Error!?Typed {
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    const record = model.declarations[@backingInt(decl.index)];
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
        .pointer => |inner| value = inner.child.*,
        .array => |inner| value = inner.*,
        .alternatives => break,
        else => break,
    };
    return switch (integer(value, pointer)) {
        .int => |int| .{ .int = int },
        else => null,
    };
}

/// The least and greatest value an inline prong's capture takes: its prong's items, each a
/// literal or a range of literals (`inline 1...7 => |period|`). Null for any other capture.
const Reach = struct { least: Magnitude, most: Magnitude };
fn prong(c: *Context, decl: Facts.Decl) ?Reach {
    const model = &c.project.at(decl.file).model;
    const tree = &c.project.at(decl.file).file.tree;
    const record = model.declarations[@backingInt(decl.index)];
    if (record.kind != .capture) return null;
    const case = tree.fullSwitchCase(record.node) orelse return null;
    if (case.inline_token == null or case.payload_token != record.token or case.ast.values.len == 0) return null;
    var out: Reach = .{ .least = std.math.maxInt(Magnitude), .most = 0 };
    for (case.ast.values) |item| {
        const low, const high = if (tree.nodeTag(item) == .switch_range) tree.nodeData(item).node_and_node else .{ item, item };
        const a = literal(tree, low) orelse return null;
        const b = literal(tree, high) orelse return null;
        out = .{ .least = @min(out.least, a), .most = @max(out.most, b) };
    }
    return out;
}

/// Whether a divisor cannot be zero: a literal other than zero, `@max(k, x)` with `k` at least
/// one, an inline prong's capture whose items are all above zero, a constant naming one, a sum
/// (`+`, which stops where it overflows) of parts at zero or above one of which is not zero, an
/// odd literal shifted left (`1 << k`: the amount's type keeps the bit within the width), or a
/// value a comparison holding where it is read puts above zero (`if (n == 0) return`, `if (x >=
/// 1)`, or above another value that cannot be negative: the `else` of `if (a >= len)`).
pub fn nonzero(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    // A divisor every path to it shows other than zero.
    return nonzeroAt(c, file, node, node, 0);
}

fn nonzeroAt(c: *Context, file: Project.FileId, node: Ast.Node.Index, at: Ast.Node.Index, depth: u8) Context.Error!bool {
    if (depth > depth_limit) return false;
    const tree = &c.project.at(file).file.tree;
    const value = bare(tree, node);
    if (literal(tree, value)) |k| return k != 0;
    if (Facts.isBuiltin(tree, value, "@max")) {
        var buffer: [2]Ast.Node.Index = undefined;
        for (Facts.builtinArgs(tree, value, &buffer)) |arg| if ((literal(tree, arg) orelse 0) >= 1) return true;
    }
    const model = &c.project.at(file).model;
    if (nameRef(model, value)) |ref| if (ref.declaration) |d| {
        if (prong(c, .{ .file = file, .index = d })) |range| if (range.least >= 1) return true;
    };
    if (constantOf(c, file, value)) |local| if (local.ast.init_node.unwrap()) |init| {
        if (try nonzeroAt(c, file, init, at, depth + 1)) return true;
    };
    if (checkedOp(tree, value)) |op| switch (op) {
        // A shift keeps a set lowest bit within the width (the amount's type is below it).
        .shl => if ((literal(tree, bare(tree, tree.nodeData(value).node_and_node[0])) orelse 0) & 1 == 1) return true,
        .add => {
            const lhs, const rhs = tree.nodeData(value).node_and_node;
            const parts = for (widths(c)) |pointer| {
                if (!try nonnegativeAt(c, file, lhs, at, pointer, depth + 1) or !try nonnegativeAt(c, file, rhs, at, pointer, depth + 1)) break false;
            } else true;
            if (parts and (try nonzeroAt(c, file, lhs, at, depth + 1) or try nonzeroAt(c, file, rhs, at, depth + 1))) return true;
        },
        else => {},
    };
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
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    // `x = -x` outside a loop: the value it makes is no value the negation reads.
    var assumed: Assumed = .{};
    if (model.parentOf(node)) |negation| if (model.parentOf(negation)) |parent| {
        if (formAt(tree, parent) == .assign and same(tree, tree.nodeData(parent).node_and_node[0], node) and !looped(tree, model, parent)) assumed.skip = parent;
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
    const tree = &c.project.at(file).file.tree;
    const at = Facts.ungrouped(tree, node);
    if (!Facts.isBuiltin(tree, at, "@as")) return false;
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
    while (model.parentOf(at)) |parent| : (at = parent) {
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
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, node);
    if (try c.facts.literalOf(file, at)) |written_here| if (written_here == .number) return std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(at))) == .float;
    if (accesses.unaryOf(tree.nodeTag(at)) == .negation) return floating(c, file, tree.nodeData(at).node);
    if (accesses.operatorOf(tree.nodeTag(at))) |operator| if (operator.overflow == .checked) switch (operator.op) {
        .add, .sub, .mul, .div, .mod => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            return try floating(c, file, lhs) or try floating(c, file, rhs);
        },
        else => {},
    };
    var value = try c.facts.resolve(file, at);
    while (true) value = switch (value) {
        .optional, .error_union => |inner| inner.*,
        .primitive => |name| return (name.len >= 2 and (name[0] == 'f' and std.ascii.isDigit(name[1]))) or std.mem.eql(u8, name, "comptime_float"),
        .alternatives => return false,
        else => return false,
    };
}

/// A constant's initializer, where it spells no type.
fn untyped(c: *Context, decl: Facts.Decl) Context.Error!?Ast.Node.Index {
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .variable) return null;
    const tree = &c.project.at(decl.file).file.tree;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const or variable.ast.type_node.unwrap() != null) return null;
    return variable.ast.init_node.unwrap();
}

/// A variable's initializer, where it spells no type: the variable is of the initializer's type.
fn inferred(c: *Context, decl: Facts.Decl) Context.Error!?Ast.Node.Index {
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .variable) return null;
    const tree = &c.project.at(decl.file).file.tree;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_var or variable.ast.type_node.unwrap() != null) return null;
    return variable.ast.init_node.unwrap();
}

/// The integer type a resolved value is, seen through an optional or an error union
/// (`Facts.integerType`).
fn integer(value: Facts.Value, pointer: u16) Typed {
    return switch (Facts.integerType(value, pointer)) {
        .int => |int| .{ .int = .{ .bits = int.bits, .signed = int.signed, .wide = int.wide, .either = int.either } },
        .literal => .literal,
        .unknown => .unknown,
    };
}

/// Where a conversion's result is read into: a type expression naming its type (what `@as`
/// names, a typed constant or variable it initializes, the parameter it is given to, the
/// function's result it returns), what it is assigned to, a struct literal's field, or the
/// backing integer of a `@fromBackingInt` or `@enumFromInt` it is given to.
const Destination = union(enum) {
    /// A type expression, read under the call's binding where it is a callee's parameter
    /// (`list.append(gpa, x)`'s `T`).
    named: struct { file: Project.FileId, node: Ast.Node.Index, env: ?*const Facts.Env = null },
    assigned: Ast.Node.Index,
    field: Facts.Decl,
    backing: Ast.Node.Index,
    /// A shift's amount, whose type is the log of the shifted value's width.
    shifted: Ast.Node.Index,
};

/// Whether a builtin's result takes its type from where it goes, its operand's being only a
/// pointer of another alignment or qualifiers.
fn leavesType(name: []const u8) bool {
    for ([_][]const u8{ "@alignCast", "@constCast", "@volatileCast", "@addrSpaceCast" }) |through| if (std.mem.eql(u8, name, through)) return true;
    return false;
}

fn destined(c: *Context, file: Project.FileId, node: Ast.Node.Index, outer: ?*const Facts.Env) Context.Error!?Destination {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    var next = node;
    while (model.parentOf(at)) |parent| : (at = next) {
        next = parent;
        switch (formAt(tree, parent)) {
            .grouped, .tried => continue,
            // A branch's value is the `if`'s: its destination is the `if`'s.
            .@"if" => {
                const branch = tree.fullIf(parent).?;
                if (branch.ast.then_expr != at and branch.ast.else_expr.unwrap() != at) return null;
                continue;
            },
            // A `break`'s value is what it leaves: the labeled block's, or the loop's.
            .@"break" => {
                if (tree.nodeData(parent).opt_token_and_opt_node[1].unwrap() != at) return null;
                next = accesses.breakTarget(tree, model, parent) orelse return null;
                continue;
            },
            .builtin => {
                const name = tree.tokenSlice(tree.nodeMainToken(parent));
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, parent, &buffer);
                if (std.mem.eql(u8, name, "@fromBackingInt") or std.mem.eql(u8, name, "@enumFromInt")) return if (args.len == 1) .{ .backing = parent } else null;
                // A cast of a pointer's alignment or qualifiers leaves its type to where it goes.
                if (args.len != 0 and args[args.len - 1] == at and leavesType(name)) continue;
                if (!std.mem.eql(u8, name, "@as")) return null;
                if (args.len != 2 or args[1] != at) return null;
                return .{ .named = .{ .file = file, .node = args[0] } };
            },
            .assign => {
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                return .{ .assigned = lhs };
            },
            .compound_assign => {
                const operator = accesses.operatorOf(tree.nodeTag(parent)).?; // unreachable: a compound assignment is `operatorOf`'s
                if (operator.overflow != .checked) return null;
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                return if (operator.op == .shl or operator.op == .shr) .{ .shifted = lhs } else .{ .assigned = lhs };
            },
            .operator => {
                const op = checkedOp(tree, parent) orelse return null;
                if (op != .shl and op != .shr) return null;
                const lhs, const rhs = tree.nodeData(parent).node_and_node;
                if (rhs != at) return null;
                return .{ .shifted = lhs };
            },
            .@"return" => {
                var scope = parent;
                while (model.parentOf(scope)) |up| : (scope = up) {
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
                if (tree.fullCall(&call_buffer, parent)) |call| return argument(c, file, call, at, outer);
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
    return switch ((try destined(c, file, node, null)) orelse return null) {
        .named => |type_node| switch (integer(try typeNamed(c, type_node, null), pointer)) {
            .int => |int| int,
            else => null,
        },
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
    filled: Magnitude,
};

fn backed(c: *Context, file: Project.FileId, call: Ast.Node.Index, pointer: u16) Context.Error!?Backing {
    var made = switch ((try destined(c, file, call, null)) orelse return null) {
        .named => |type_node| try typeNamed(c, type_node, null),
        .assigned => |lhs| try c.facts.resolve(file, lhs),
        .field => |decl| try c.facts.declaration(decl),
        .backing, .shifted => return null,
    };
    while (made == .optional) made = made.optional.*;
    const container = switch (made) {
        .container, .instance => |k| k,
        .alternatives => return null,
        else => return null,
    };
    const tree = &c.project.at(container.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const declared = tree.fullContainerDecl(&buffer, c.project.at(container.file).model.scopes[@backingInt(container.scope)].node) orelse return null;
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
        const each = c.project.at(container.file).model.containerField(tree, member) orelse continue;
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
    var filled_to: ?Magnitude = null;
    for (values.items) |value| {
        const expected: Magnitude = if (filled_to) |f| f + 1 else 0;
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
        if (!atMost(magnitude, backing.filled)) return false;
    }
    return true;
}

/// Where the parameter `arg` is given to declares its type, where the call resolves.
fn argument(c: *Context, file: Project.FileId, call: Ast.full.Call, arg: Ast.Node.Index, outer: ?*const Facts.Env) Context.Error!?Destination {
    const tree = &c.project.at(file).file.tree;
    const position_of = std.mem.findScalar(Ast.Node.Index, call.ast.params, arg) orelse return null;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        .alternatives => return null,
        else => return null,
    };
    // A method called on a value takes it as its first parameter.
    var skip: usize = 0;
    if (formAt(tree, call.ast.fn_expr) == .member) {
        var receiver = try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        if (receiver == .pointer) receiver = receiver.pointer.child.*;
        if (receiver == .instance) skip = 1;
    }
    const callee_tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = callee_tree.fullFnProto(&buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return null;
    var it = proto.iterate(callee_tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        if (index != position_of + skip) continue;
        return .{ .named = .{ .file = decl.file, .node = param.type_expr orelse return null, .env = try c.facts.bind(file, call, decl, outer) } };
    }
    return null;
}

/// The type a destination's type expression names, under the call's binding where it has one,
/// else under `outer`, the reading of the function it is written in.
fn typeNamed(c: *Context, type_node: @FieldType(Destination, "named"), outer: ?*const Facts.Env) Context.Error!Facts.Value {
    const env = type_node.env orelse outer orelse return c.facts.resolve(type_node.file, type_node.node);
    return c.facts.resolveBound(env, type_node.file, type_node.node);
}

/// The field a struct literal's `value` initializes.
fn field(c: *Context, file: Project.FileId, literal_node: Ast.Node.Index, value: Ast.Node.Index) Context.Error!?Facts.Decl {
    const tree = &c.project.at(file).file.tree;
    var holder = try c.facts.literalType(file, literal_node);
    while (true) holder = switch (holder) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        .alternatives => break,
        else => break,
    };
    const container = switch (holder) {
        .container, .instance => |k| k,
        .alternatives => return null,
        else => return null,
    };
    const name = tree.tokenSlice(Model.initName(tree, value) orelse return null);
    const decl = c.facts.member(container, name) orelse return null;
    if (c.project.at(decl.file).model.declarations[@backingInt(decl.index)].kind != .field) return null;
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
    switch (formAt(tree, node)) {
        // A number's or a character's token is its own kind.
        .leaf => switch (tree.tokenTag(tree.nodeMainToken(node))) {
            .number_literal => return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
                .int => |value| value,
                else => null,
            },
            .char_literal => return switch (std.zig.string_literal.parseCharLiteral(tree.tokenSlice(tree.nodeMainToken(node)))) {
                .success => |code| code,
                .failure => null,
            },
            else => return null,
        },
        .grouped => return literal(tree, tree.nodeData(node).node_and_token[0]),
        .operator => {
            const op = checkedOp(tree, node) orelse return null;
            if (op != .add and op != .sub and op != .mul) return null;
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            const a = literal(tree, lhs) orelse return null;
            const b = literal(tree, rhs) orelse return null;
            return switch (op) {
                .add => std.math.add(u64, a, b) catch null,
                .sub => std.math.sub(u64, a, b) catch null,
                else => std.math.mul(u64, a, b) catch null,
            };
        },
        else => return null,
    }
}

fn narrower(a: ?Magnitude, b: ?Magnitude) ?Magnitude {
    const x = a orelse return b;
    const y = b orelse return a;
    return @min(x, y);
}

fn wider(a: ?Magnitude, b: ?Magnitude) ?Magnitude {
    return @max(a orelse return null, b orelse return null);
}

fn sum(a: ?Magnitude, b: ?Magnitude) ?Magnitude {
    return (a orelse return null) +| (b orelse return null);
}

fn shifted(a: ?Magnitude, by: u64) ?Magnitude {
    const left = a orelse return null;
    if (left == 0) return 0;
    if (by >= @bitSizeOf(Magnitude) or left > @as(Magnitude, std.math.maxInt(Magnitude)) >> @intCast(by)) return std.math.maxInt(Magnitude);
    return left << @intCast(by);
}

/// Whether a magnitude is shown at most `limit`. The bounds saturate at the greatest `Magnitude` (a sum
/// past it, `filled` of a type of 128 bits or more), so one there may be past any limit: a sum
/// past a `u128` read as fitting it.
fn atMost(magnitude: Magnitude, limit: Magnitude) bool {
    return magnitude < std.math.maxInt(Magnitude) and magnitude <= limit;
}

/// The greatest value of `bits` bits.
fn filled(bits: u16) Magnitude {
    return if (bits >= @bitSizeOf(Magnitude)) std.math.maxInt(Magnitude) else (@as(Magnitude, 1) << @intCast(bits)) - 1;
}

/// An integer wide enough for every value of a type of at most 256 bits, its sign included.
const Wide = i258;

/// The type Zig gives `@min` (`smallest`) or `@max` of integers: the narrowest that holds
/// every value the result can take (`std.math.IntFittingRange` over the operands' ranges), a
/// comptime-known operand read by its value and a runtime one by its type's range:
/// `@min(a: u8, b: u64)` is a `u8`, `@min(b, 255)` a `u8`, `@max(a, 300)` a `u9`, so a step
/// past it overflows the narrower type. A comptime number where every operand is
/// comptime-known. Unknown where an operand's range is not shown: one that may be
/// comptime-known with a value no constant gives, or a type whose width differs between
/// targets.
fn minMaxType(c: *Context, file: Project.FileId, args: []const Ast.Node.Index, smallest: bool, pointer: u16, depth: u8) Context.Error!Typed {
    var lo: Wide = 0;
    var hi: Wide = 0;
    var known = true;
    for (args, 0..) |arg, i| {
        const range = (try operandRange(c, file, arg, pointer, depth)) orelse return .unknown;
        known = known and range.known;
        if (i == 0) {
            lo, hi = .{ range.lo, range.hi };
        } else if (smallest) {
            lo, hi = .{ @min(lo, range.lo), @min(hi, range.hi) };
        } else {
            lo, hi = .{ @max(lo, range.lo), @max(hi, range.hi) };
        }
    }
    if (known) return .literal;
    // The largest magnitude either end needs, its sign a bit more where the low end is below 0.
    const largest = @max(if (lo < 0) -lo - 1 else lo, hi);
    const magnitude: u16 = @bitSizeOf(Wide) - @as(u16, @clz(largest));
    return .{ .int = if (lo < 0) .{ .bits = magnitude + 1, .signed = true } else .{ .bits = magnitude, .signed = false } };
}

/// The values an operand of `@min` or `@max` may have, as Zig reads them for its type: a
/// constant's value (`known`), or a runtime value's type's range (`atRuntime`). Null where
/// neither is shown.
fn operandRange(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16, depth: u8) Context.Error!?struct { lo: Wide, hi: Wide, known: bool } {
    const tree = &c.project.at(file).file.tree;
    const at = Facts.ungrouped(tree, node);
    if (try valueOf(c, file, at, 0)) |value| return .{ .lo = value, .hi = value, .known = true };
    if (accesses.unaryOf(tree.nodeTag(at)) == .negation) if (try valueOf(c, file, tree.nodeData(at).node, 0)) |value| return .{ .lo = -@as(Wide, value), .hi = -@as(Wide, value), .known = true };
    // An array's length is its type's, known as the program compiles.
    if (try c.facts.lengthOf(file, at)) |memory| if (try fixedLength(c, file, memory)) |fixed| return .{ .lo = fixed, .hi = fixed, .known = true };
    const int = switch (try typeOf(c, file, at, pointer, depth)) {
        .int => |int| int,
        else => return null,
    };
    if (int.wide != null or int.either or int.bits > 256 or !try atRuntime(c, file, at, null, 0)) return null;
    if (!int.signed) return .{ .lo = 0, .hi = (@as(Wide, 1) << @intCast(int.bits)) - 1, .known = false };
    if (int.bits == 0) return .{ .lo = 0, .hi = 0, .known = false };
    const half = @as(Wide, 1) << @intCast(int.bits - 1);
    return .{ .lo = -half, .hi = half - 1, .known = false };
}

/// How deep `atRuntime` follows a value through constants, conversions and `inline` calls'
/// bodies (std's `Reader.takeInt` is three `inline` calls deep). Past it a value may be known.
const runtime_depth = 32;

/// Whether `node` is a value known only at run time, which Zig reads by its type's range: a
/// `var`, a parameter neither `comptime`, a type nor `anytype`, a function's constant such a
/// value initializes, a call of a function that is not `inline`, an `inline` one's whose every
/// `return` gives such a value (its parameters read as the call's arguments, `given`), and
/// what arithmetic, a conversion, an index, a dereference, an unwrap, a field of such a value,
/// or an `if` or `switch` whose every branch gives one makes; a slice's `len` where the slice is
/// one. False where it may be known as the program compiles (a literal, a container's constant,
/// a `comptime` parameter, an array's `len`, a capture).
fn atRuntime(c: *Context, file: Project.FileId, node: Ast.Node.Index, given: ?*const InlineCall, depth: u8) Context.Error!bool {
    if (depth > runtime_depth) return false;
    const tree = &c.project.at(file).file.tree;
    const next = depth + 1;
    switch (formAt(tree, node)) {
        .grouped, .unwrap_optional => return atRuntime(c, file, tree.nodeData(node).node_and_token[0], given, next),
        .tried, .deref => return atRuntime(c, file, tree.nodeData(node).node, given, next),
        .@"orelse", .@"catch" => return atRuntime(c, file, tree.nodeData(node).node_and_node[0], given, next),
        .operator => {
            if (accesses.unaryOf(tree.nodeTag(node)) != null) return atRuntime(c, file, tree.nodeData(node).node, given, next);
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try atRuntime(c, file, lhs, given, next) or try atRuntime(c, file, rhs, given, next);
        },
        .array_access => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            return try atRuntime(c, file, lhs, given, next) or try atRuntime(c, file, rhs, given, next);
        },
        .@"if" => {
            const branch = tree.fullIf(node).?;
            const otherwise = branch.ast.else_expr.unwrap() orelse return false;
            return try atRuntime(c, file, branch.ast.then_expr, given, next) and try atRuntime(c, file, otherwise, given, next);
        },
        .@"switch" => {
            const choice = tree.fullSwitch(node).?;
            for (choice.ast.cases) |case| if (!try atRuntime(c, file, tree.fullSwitchCase(case).?.ast.target_expr, given, next)) return false;
            return choice.ast.cases.len != 0;
        },
        .member => {
            const receiver = tree.nodeData(node).node_and_token[0];
            if (!try atRuntime(c, file, receiver, given, next)) return false;
            switch (try c.facts.languageField(file, node)) {
                // An array's length is its type's; a slice's is the slice's.
                .len => {
                    var memory = try c.facts.resolve(file, receiver);
                    if (memory == .pointer and memory.pointer.size == .one) memory = memory.pointer.child.*;
                    return memory == .pointer and memory.pointer.size == .slice;
                },
                .ptr, .none => return c.facts.runtime(file, node),
                // May be an array's, known as the program compiles.
                .unknown => return false,
            }
        },
        .call => {
            const call = (try Facts.calls.at(c.facts, file, node)) orelse return false;
            const callees: []const Facts.Decl = switch (call.callee) {
                .function => |decl| &.{decl},
                .choice => |each| each,
                .any => return false,
            };
            for (callees) |callee| if (!try returnsRuntime(c, call, callee, given, next)) return false;
            return true;
        },
        .builtin => {
            const value_builtins = [_][]const u8{ "@as", "@intCast", "@truncate", "@bitCast", "@intFromEnum", "@intFromBool", "@intFromFloat", "@intFromPtr", "@min", "@max", "@abs", "@popCount", "@ctz", "@clz", "@byteSwap", "@bitReverse", "@divFloor", "@divTrunc", "@divExact", "@mod", "@rem", "@shlExact", "@shrExact" };
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            for (value_builtins) |each| if (std.mem.eql(u8, name, each)) {
                var buffer: [2]Ast.Node.Index = undefined;
                for (Facts.builtinArgs(tree, node, &buffer)) |arg| if (try atRuntime(c, file, arg, given, next)) return true;
                return false;
            };
            return false;
        },
        .leaf => {
            const model = &c.project.at(file).model;
            const index = (nameRef(model, node) orelse return false).declaration orelse return false;
            const record = model.declarations[@backingInt(index)];
            switch (record.kind) {
                .parameter => {
                    if (c.facts.comptimeParameter(file, node)) return false;
                    // An `inline` function's parameter is what the call gives it.
                    if (given) |call| if (call.callee.file == file) if (call.parameterAt(c, index)) |at| {
                        const args = call.call.args.known;
                        if (at >= args.len) return false;
                        return atRuntime(c, call.call.file, args[at], call.outer, next);
                    };
                    const type_expr = c.facts.parameterTypeNode(.{ .file = file, .index = index }) orelse return false;
                    return !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "type");
                },
                .variable => {
                    const scope = model.scopes[@backingInt(record.scope)];
                    var container: [2]Ast.Node.Index = undefined;
                    if (scope.node == .root or tree.fullContainerDecl(&container, scope.node) != null) return false;
                    const variable = tree.fullVarDecl(record.node) orelse return false;
                    if (variable.comptime_token != null) return false;
                    if (tree.tokenTag(variable.ast.mut_token) == .keyword_var) return true;
                    return atRuntime(c, file, variable.ast.init_node.unwrap() orelse return false, given, next);
                },
                else => return false,
            }
        },
        else => return false,
    }
}

/// An `inline` function's call `atRuntime` reads its body in: its parameters are the call's
/// arguments, read where the call is (`outer`).
const InlineCall = struct {
    call: Facts.calls.Call,
    callee: Facts.Decl,
    outer: ?*const InlineCall,

    /// The position among the call's arguments of the callee's parameter `index`.
    fn parameterAt(self: *const InlineCall, c: *Context, index: Model.Declaration.Id) ?usize {
        const tree = &c.project.at(self.callee.file).file.tree;
        const record = c.project.at(self.callee.file).model.declarations[@backingInt(index)];
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, c.project.at(self.callee.file).model.declarations[@backingInt(self.callee.index)].node) orelse return null;
        var it = proto.iterate(tree);
        var at: usize = 0;
        while (it.next()) |param| : (at += 1) if (param.name_token == record.token) return at;
        return null;
    }
};

/// Whether a call of `callee` gives a value known only at run time: any function's but an
/// `inline` one's, and an `inline` one's where every `return` in its body gives one, read with
/// its parameters as the call's arguments.
fn returnsRuntime(c: *Context, call: Facts.calls.Call, callee: Facts.Decl, outer: ?*const InlineCall, depth: u8) Context.Error!bool {
    const declared = &c.project.at(callee.file).file.tree;
    const model = &c.project.at(callee.file).model;
    const record = model.declarations[@backingInt(callee.index)];
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = declared.fullFnProto(&proto_buffer, record.node) orelse return false;
    const qualifier = proto.extern_export_inline_token orelse return true;
    if (declared.tokenTag(qualifier) != .keyword_inline) return true;
    if (call.args != .known) return false;
    // A function's declaration is its prototype, its body the `fn_decl` holding it.
    const whole = if (declared.nodeTag(record.node) == .fn_decl) record.node else model.parentOf(record.node) orelse return false;
    if (declared.nodeTag(whole) != .fn_decl) return false;
    const body = declared.nodeData(whole).node_and_node[1];
    const given: InlineCall = .{ .call = call, .callee = callee, .outer = outer };
    var returns: usize = 0;
    const first = declared.firstToken(body);
    const last = declared.lastToken(body);
    for (0..declared.nodes.len) |i| {
        const at: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (declared.nodeTag(at) != .@"return") continue;
        const token = declared.nodeMainToken(at);
        if (token < first or token > last) continue;
        const value = declared.nodeData(at).opt_node.unwrap() orelse return false;
        if (!try atRuntime(c, callee.file, value, &given, depth)) return false;
        returns += 1;
    }
    return returns != 0;
}

/// The greatest length of memory at a pointer width: below half the address space.
fn length(pointer: u16) Magnitude {
    return filled(std.math.sub(u16, pointer, 1) catch 0);
}

/// A quotient's bound: the dividend's divided by a literal divisor.
fn quotient(dividend: ?Magnitude, divisor: ?u64) ?Magnitude {
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
    return (try gathered(c, file, node)).held;
}

/// Every fact holding where `node` is evaluated, the forms only a position's judgement reads
/// with them: besides the comparisons, the positions read before it (a switch's operand
/// `m[i]`, a compared `m[i]`), what an aegis `assert.invariant` before it checked, and where
/// a std search a branch or loop takes the result of put that result.
fn gather(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Fact {
    return (try gathered(c, file, node)).all;
}

/// What `gather` and `facts` give at a position under the settled conditions in force.
const Gathered = struct { all: []const Fact, held: []const Fact };
const GatherKey = struct { file: Project.FileId, node: Ast.Node.Index, assumed: @FieldType(Facts, "assumed") };
const Gatherings = struct { found: std.AutoHashMapUnmanaged(GatherKey, Gathered) = .empty };

/// Read once per position for the run, every sink and bound asking at it again and again, and
/// kept by the core's one memo rule: only where no budget ran out and no wider answer or open
/// query was read meanwhile.
fn gathered(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!Gathered {
    const key: GatherKey = .{ .file = file, .node = node, .assumed = c.facts.assumed };
    if ((try c.facts.memo(Gatherings)).found.get(key)) |known| return known;
    const wide = c.facts.wide;
    const met = c.facts.open_met;
    const was_short = c.facts.short;
    const all = try gatherAt(c, file, node);
    var comparisons: std.ArrayList(Fact) = .empty;
    for (all) |fact| if (!fact.differs and !fact.read) try comparisons.append(c.allocator, fact);
    if (c.facts.remaining == 0 or c.facts.wideSince(wide) or c.facts.open_met != met or c.facts.short != was_short) return .{ .all = all, .held = comparisons.items };
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memoized: Gathered = .{ .all = try c.allocator.dupe(Fact, all), .held = try c.allocator.dupe(Fact, comparisons.items) };
    // Asked again: a walk read meanwhile may have replaced the memo (`Facts.dropMemos`).
    try (try c.facts.memo(Gatherings)).found.put(c.allocator, key, memoized);
    return memoized;
}

fn gatherAt(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Fact {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var out: std.ArrayList(Fact) = .empty;
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        switch (formAt(tree, parent)) {
            .fn_decl => break,
            // The right side of `a and b` is read where `a` is true, of `a or b` where it is false.
            .logic => switch (Facts.conditionOf(tree, parent)) {
                .both => |sides| if (sides[1] == at) try held(c, file, &out, sides[0], true, node),
                .either => |sides| if (sides[1] == at) try held(c, file, &out, sides[0], false, node),
                .not, .compare, .other => {},
            },
            .body => {
                var buffer: [2]Ast.Node.Index = undefined;
                for (tree.blockStatements(&buffer, parent) orelse &.{}) |statement| {
                    if (statement == at) break;
                    try limited(c, file, &out, statement, node);
                    try subtracted(c, file, &out, statement, node);
                    try reserved(c, file, &out, statement, node);
                    try asserted(c, file, &out, statement, node);
                    try succeeded(c, file, &out, statement, node);
                    if (tree.fullVarDecl(statement)) |local| if (local.ast.init_node.unwrap()) |init| {
                        try searchFacts(c, file, &out, init, node);
                        try readFacts(c, file, &out, init, node);
                        try succeeded(c, file, &out, init, node);
                    };
                    const branch = tree.fullIf(statement) orelse continue;
                    if (branch.ast.else_expr != .none) continue;
                    if (leaves(tree, branch.ast.then_expr)) {
                        try held(c, file, &out, branch.ast.cond_expr, false, node);
                    } else try clamped(c, file, &out, branch, statement, node);
                }
            },
            .@"switch" => {
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
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, access);
    if (formAt(tree, at) != .array_access) return;
    const memory, const index = tree.nodeData(at).node_and_node;
    if (!try kept(c, file, memory, since orelse access, use) or !try kept(c, file, index, since orelse access, use)) return;
    try out.append(c.allocator, .{ .small = index, .large = memory, .strict = true, .read = true });
}

/// What a difference computed before the use left: `a - b` of unsigned operands, evaluated on
/// every path through `statement` (`if (len > in.len - ip) return` before `in[ip..]`), puts
/// `b` at most `a` past it, while nothing between assigns either. A difference that would
/// underflow stops the program there, at the subtraction, which A010 judges itself.
fn subtracted(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
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
    if (start > all.len) return;
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
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Differences);
    const entry = try memo.files.getOrPut(c.allocator, @backingInt(file));
    if (entry.found_existing) return entry.value_ptr.*;
    const tree = &c.project.at(file).file.tree;
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
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var at = node;
    while (at != root) {
        const parent = model.parentOf(at) orelse return false;
        switch (Model.runsWith(tree, parent, at)) {
            .always, .sequenced, .labeled, .compile_time => {},
            .branch, .loop, .deferred, .unevaluated, .function => return false,
        }
        at = parent;
    }
    return true;
}

/// What a method call that succeeded checked: `try r.f(…)` where `f`, in this file, fails
/// unless a condition on its receiver holds, by `return if (c) … else error.X;` or by
/// `if (c) return error.X;` guards among its statements (`fn byte(self) !u8 { return if
/// (self.at < self.input.len) self.input[self.at] else error.SyntaxError; }`, `fn enter(self)
/// !void { self.depth += 1; if (self.depth > max) return error.TooDeep; }`). A guard counts
/// where no statement before it returns without failing, so a call that succeeded passed it, and
/// nothing that runs after it, its function's defers included, may write what the caller can
/// see (`quiet`), so what it saw still holds. The condition is read with the receiver for the
/// first parameter, so only where the call spells its receiver as `f` names it and the
/// condition names nothing of `f`'s but it; it holds from the call while nothing after it
/// assigns what it compares.
fn succeeded(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), value: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const attempt = bare(tree, value);
    if (tree.nodeTag(attempt) != .@"try") return;
    const call_node = tree.nodeData(attempt).node;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return;
    if (formAt(tree, call.ast.fn_expr) != .member) return;
    const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    if (callee != .function or callee.function.file != file) return;
    const proto_node = model.declarations[@backingInt(callee.function.index)].node;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, proto_node) orelse return;
    var parameters = proto.iterate(tree);
    const first = parameters.next() orelse return;
    const self_token = first.name_token orelse return;
    const self_name = tree.tokenSlice(self_token);
    if (!std.mem.eql(u8, std.mem.trim(u8, tree.getNodeSource(receiver), " "), self_name)) return;
    const function = model.parentOf(proto_node) orelse return;
    if (tree.nodeTag(function) != .fn_decl) return;
    var statement_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&statement_buffer, tree.nodeData(function).node_and_node[1]) orelse return;
    // A `defer` runs as the function returns, after every guard: what it writes is written
    // after them all. An `errdefer` runs only where the call failed.
    for (statements) |statement| if (tree.nodeTag(statement) == .@"defer" and !try quiet(c, file, function, &.{statement})) return;
    for (statements, 0..) |statement, at| {
        if (tree.nodeTag(statement) == .@"return") {
            const result = tree.nodeData(statement).opt_node.unwrap() orelse return;
            const branch = tree.fullIf(bare(tree, result)) orelse return;
            const otherwise = branch.ast.else_expr.unwrap() orelse return;
            if (!receiverOnly(tree, model, branch.ast.cond_expr, function, self_token)) return;
            if (try errorValue(c, file, otherwise) and try quiet(c, file, function, &.{branch.ast.then_expr})) return holds(c, file, out, branch.ast.cond_expr, true, use, call_node);
            if (try errorValue(c, file, branch.ast.then_expr) and try quiet(c, file, function, &.{otherwise})) return holds(c, file, out, branch.ast.cond_expr, false, use, call_node);
            return;
        }
        if (try returnsQuietly(c, file, statement)) return;
        const branch = tree.fullIf(statement) orelse continue;
        if (branch.ast.else_expr != .none or !try failing(c, file, branch.ast.then_expr) or !receiverOnly(tree, model, branch.ast.cond_expr, function, self_token)) continue;
        if (!try quiet(c, file, function, statements[at + 1 ..])) continue;
        try holds(c, file, out, branch.ast.cond_expr, false, use, call_node);
    }
}

/// Whether `statement` may return without failing: a `return` in it that gives no error value.
fn returnsQuietly(c: *Context, file: Project.FileId, statement: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const first = tree.firstToken(statement);
    const last = tree.lastToken(statement);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const result = tree.nodeData(node).opt_node.unwrap() orelse return true;
        if (!try errorValue(c, file, result)) return true;
    }
    return false;
}

/// Whether `nodes`, run in `function`, write nothing its caller can see: each store is to a
/// local of `function` by its own name, and nothing else stores. Any other store may reach
/// what the caller compares, whatever its spelling (`other.at` with `other` the receiver,
/// `@field(self, "at")`, `q.at` with `q = self`, a pointer read from a field, a global the
/// receiver may be); so may a call that can write (all but `inert` ones), a builtin that
/// writes memory, and `asm`.
fn quiet(c: *Context, file: Project.FileId, function: Ast.Node.Index, nodes: []const Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    for (nodes) |whole| {
        const first = tree.firstToken(whole);
        const last = tree.lastToken(whole);
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const token = tree.nodeMainToken(node);
            if (token < first or token > last) continue;
            switch (accesses.formOf(tag)) {
                .assign, .compound_assign => if (!ownLocal(tree, model, tree.nodeData(node).node_and_node[0], function)) return false,
                .destructure => for (tree.assignDestructure(node).ast.variables) |target| {
                    const a_name = nameRef(model, target) != null or discards(tree, target);
                    if (a_name and !ownLocal(tree, model, target, function)) return false;
                    // A declaration is a new local; anything else is a store.
                    if (!a_name and tree.fullVarDecl(target) == null) return false;
                },
                .call => if (!try inert(c, file, node)) return false,
                .builtin => if (writesMemory(tree.tokenSlice(token))) return false,
                .@"asm" => return false,
                else => {},
            }
        }
    }
    return true;
}

/// Whether a store's `target` is a local of `function` by its own name (`_` discards).
fn ownLocal(tree: *const Ast, model: *const Model, target: Ast.Node.Index, function: Ast.Node.Index) bool {
    if (discards(tree, target)) return true;
    const d = (nameRef(model, target) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(d)];
    return record.kind == .variable and record.token >= tree.firstToken(function) and record.token <= tree.lastToken(function);
}

/// Whether a callee's condition names nothing of its function's but its receiver (the first
/// parameter, `self_token`): what it says of the receiver is what the caller's receiver holds.
/// Another parameter, a local or a capture of the callee read in the caller would be whatever
/// the caller's code spells that way.
fn receiverOnly(tree: *const Ast, model: *const Model, condition: Ast.Node.Index, function: Ast.Node.Index, self_token: Ast.TokenIndex) bool {
    const first = tree.firstToken(condition);
    const last = tree.lastToken(condition);
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!spellsName(tree, node)) continue;
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        // A name the model cannot place may be anything of the callee's.
        const reference = model.reference(node) orelse return false;
        const d = reference.declaration orelse {
            if (reference.unknown == .primitive) continue;
            return false;
        };
        const record = model.declarations[@backingInt(d)];
        if (record.token == self_token) continue;
        if (record.token >= tree.firstToken(function) and record.token <= tree.lastToken(function)) return false;
    }
    return true;
}

/// Whether a branch only fails: `return error.X;`, alone or as a block's one statement.
fn failing(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    switch (formAt(tree, node)) {
        .@"return" => {
            const result = tree.nodeData(node).opt_node.unwrap() orelse return false;
            return errorValue(c, file, result);
        },
        .body => {
            var buffer: [2]Ast.Node.Index = undefined;
            const statements = tree.blockStatements(&buffer, node) orelse return false;
            return statements.len == 1 and try failing(c, file, statements[0]);
        },
        else => return false,
    }
}

/// What an aegis `assert.invariant(condition, …)` statement checked: it stops the program in
/// every build where the condition fails, so the condition holds after it.
fn asserted(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
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
    const tree = &c.project.at(file).file.tree;
    const search = (try searched(c, file, value)) orelse return;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, search).?; // unreachable: `searched` gives a call
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    const kind = (try stdSearch(c, callee.function)) orelse return; // `searched` read it as a function
    const scalar = kind.scalar;
    const from = kind.from;
    if (call.ast.params.len < (if (from) @as(usize, 4) else 3)) return;
    const haystack = call.ast.params[1];
    if (!try kept(c, file, haystack, value, use)) return;
    // The search's value is the position its capture or constant names: below `h.len`.
    try out.append(c.allocator, .{ .small = search, .large = haystack, .strict = scalar, .read = true });
    if (from and try kept(c, file, call.ast.params[2], value, use)) try out.append(c.allocator, .{ .small = call.ast.params[2], .large = search, .strict = false });
}

/// std's searches whose result a read position is bound by: `scalar`, a position below the
/// haystack's length (a needle's search is at most it: an empty needle is found at the end), and
/// `from`, one at or after the start it is given.
const std_searches = [_]struct { path: []const u8, scalar: bool, from: bool }{
    .{ .path = "mem.find", .scalar = false, .from = false },
    .{ .path = "mem.findPos", .scalar = false, .from = true },
    .{ .path = "mem.findScalar", .scalar = true, .from = false },
    .{ .path = "mem.findScalarLast", .scalar = true, .from = false },
    .{ .path = "mem.findScalarPos", .scalar = true, .from = true },
    .{ .path = "mem.findAny", .scalar = true, .from = false },
    .{ .path = "mem.findAnyPos", .scalar = true, .from = true },
};

/// The entry of `std_searches` that `function` is, by its declaration (`Governed.isStd`).
fn stdSearch(c: *Context, function: Facts.Decl) Context.Error!?@typeInfo(@TypeOf(std_searches)).array.child {
    if (!try c.facts.standard(function.file)) return null;
    for (std_searches) |each| if (try Governed.isStd(c, function, each.path) == .yes) return each;
    return null;
}

/// std's reads, which return how many bytes they put in the buffers they are given: at most
/// those buffers' total length, std's promise by declaration. `param` names the buffers, one
/// slice or a vector of them (a method's receiver is parameter 0).
const std_reads = [_]struct { path: []const u8, param: usize }{
    .{ .path = "posix.read", .param = 1 },
    .{ .path = "Io.File.readStreaming", .param = 2 },
    .{ .path = "Io.File.readPositional", .param = 2 },
    .{ .path = "Io.net.Stream.read", .param = 2 },
    .{ .path = "Io.Reader.readVec", .param = 1 },
    .{ .path = "Io.Reader.readSliceShort", .param = 1 },
};

/// What a read's count holds where a constant takes it (`const n = try f.readStreaming(io,
/// &.{chunk[0..m]})`): at most the length of the one buffer it filled. A slice `x[s..e]` is
/// at most `e` long; another buffer is named whole, its length a read position's bound. A
/// vector of several buffers, or one not spelled, says nothing.
fn readFacts(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), value: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
    const call = givenCall(tree, value) orelse return;
    const buffers = (try readBuffers(c, file, call, 0)) orelse return;
    var one = bare(tree, buffers);
    var buffer: [2]Ast.Node.Index = undefined;
    if (formAt(tree, one) == .address_of and tree.fullArrayInit(&buffer, tree.nodeData(one).node) != null) {
        const vector = tree.fullArrayInit(&buffer, tree.nodeData(one).node).?; // unreachable: just read
        if (vector.ast.elements.len != 1) return;
        one = bare(tree, vector.ast.elements[0]);
    } else {
        // One buffer of bytes, a slice or an array's address, not a vector held elsewhere.
        const bytes = switch (try c.facts.resolve(file, one)) {
            .pointer => |item| item.child.* == .primitive or (item.child.* == .array and item.child.array.* == .primitive),
            .alternatives => false,
            else => false,
        };
        if (!bytes) return;
        if (formAt(tree, one) == .address_of) one = bare(tree, tree.nodeData(one).node);
    }
    if (tree.fullSlice(one)) |slice| {
        const end = slice.ast.end.unwrap() orelse return;
        if (!try kept(c, file, end, value, use)) return;
        try out.append(c.allocator, .{ .small = call, .large = end, .strict = false });
        return;
    }
    if (!try kept(c, file, one, value, use)) return;
    try out.append(c.allocator, .{ .small = call, .large = one, .strict = false, .read = true });
}

/// The call `value` gives: itself, past `try`, and past a `catch` or `orelse` whose other side
/// leaves (every prong of a `switch` on the error leaving too).
fn givenCall(tree: *const Ast, value: Ast.Node.Index) ?Ast.Node.Index {
    var at = bare(tree, value);
    while (true) switch (formAt(tree, at)) {
        .tried => at = bare(tree, tree.nodeData(at).node),
        .@"catch", .@"orelse" => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            if (!leavesAll(tree, rhs)) return null;
            at = bare(tree, lhs);
        },
        .call => return at,
        else => return null,
    };
}

/// Whether `node` leaves on every way through it: `leaves`, or a `switch` each prong of which does.
fn leavesAll(tree: *const Ast, node: Ast.Node.Index) bool {
    if (leaves(tree, node)) return true;
    const choice = tree.fullSwitch(node) orelse return false;
    for (choice.ast.cases) |case| if (!leavesAll(tree, tree.fullSwitchCase(case).?.ast.target_expr)) return false; // unreachable: a switch's cases are cases
    return true;
}

/// The argument naming the buffers a read call fills: the call reaches one of `std_reads`, or a
/// function of the program each value of which it returns is such a read of one parameter, the
/// same one (a read retried until it makes progress).
fn readBuffers(c: *Context, file: Project.FileId, call_node: Ast.Node.Index, depth: u8) Context.Error!?Ast.Node.Index {
    if (depth == 4) return null;
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, call_node) orelse return null;
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    if (callee != .function) return null;
    const decl = ((try c.facts.origin(callee.function)).orNull()) orelse callee.function;
    const param = (try readParam(c, decl, depth)) orelse return null;
    // A method call hands its receiver first.
    var skip: usize = 0;
    if (formAt(tree, call.ast.fn_expr) == .member) switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
        .instance, .pointer, .optional => skip = 1,
        // A choice may or may not hand a receiver first: which argument is not known.
        .alternatives => return null,
        else => {},
    };
    if (param < skip or param - skip >= call.ast.params.len) return null;
    return call.ast.params[param - skip];
}

/// The parameter of `decl` naming the buffers whose total length bounds what it returns: a
/// `std_reads` entry's, or, for a function of the program, the one every value it returns
/// reads into, directly or through a constant (`const n = try f.readStreaming(io, buffers);
/// if (n != 0) return n;`). An error it returns gives no count.
fn readParam(c: *Context, decl: Facts.Decl, depth: u8) Context.Error!?usize {
    for (std_reads) |each| for (((try Governed.declarations(c, "std", each.path)).orNull()) orelse &.{}) |found| {
        if (std.meta.eql(((try c.facts.origin(found)).orNull()) orelse found, decl)) return each.param;
    };
    if (!try Program.owns(c, decl.file)) return null;
    const tree = &c.project.at(decl.file).file.tree;
    const model = &c.project.at(decl.file).model;
    const function = model.parentOf(model.declarations[@backingInt(decl.index)].node) orelse return null;
    if (tree.nodeTag(function) != .fn_decl) return null;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, model.declarations[@backingInt(decl.index)].node) orelse return null;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    var found: ?usize = null;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (token < first or token > last) continue;
        const result = tree.nodeData(node).opt_node.unwrap() orelse return null;
        if (try errorValue(c, decl.file, result)) continue;
        var reading = givenCall(tree, result);
        if (reading == null) if (constantOf(c, decl.file, bare(tree, result))) |local| {
            reading = givenCall(tree, local.ast.init_node.unwrap() orelse return null);
        };
        const buffers = (try readBuffers(c, decl.file, reading orelse return null, depth + 1)) orelse return null;
        const spelled = bare(tree, buffers);
        const d = (nameRef(model, spelled) orelse return null).declaration orelse return null;
        if (model.declarations[@backingInt(d)].kind != .parameter) return null;
        var it = proto.iterate(tree);
        var place: usize = 0;
        const at = while (it.next()) |p| : (place += 1) {
            if (p.name_token == model.declarations[@backingInt(d)].token) break place;
        } else return null;
        if (found) |other| if (other != at) return null;
        found = at;
    }
    return found;
}

/// The std search call `value` is, alone or before an `orelse` that leaves, by the function it
/// calls (`stdSearch`). Such a search is pure, so a capture or constant holding its
/// value is one value with the call while its arguments are kept.
fn searched(c: *Context, file: Project.FileId, value: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var at = bare(tree, value);
    if (formAt(tree, at) == .@"orelse") {
        const lhs, const rhs = tree.nodeData(at).node_and_node;
        if (!leaves(tree, rhs)) return null;
        at = bare(tree, lhs);
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, at) orelse return null;
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    if (callee != .function) return null;
    return if (try stdSearch(c, callee.function) != null) at else null;
}

/// The comparisons `condition` gives where it is `truth`, and still holds at `use`.
fn held(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), condition: Ast.Node.Index, truth: bool, use: Ast.Node.Index) Context.Error!void {
    return holds(c, file, out, condition, truth, use, null);
}

/// `held`, with what is compared kept from `since` to `use` where given: a condition a callee
/// checked is read from its call, not from where the callee is written.
fn holds(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), condition: Ast.Node.Index, truth: bool, use: Ast.Node.Index, since: ?Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
    const form = Facts.conditionOf(tree, condition);
    switch (form) {
        .not => |inner| return holds(c, file, out, inner, !truth, use, since),
        // Both sides hold where `a and b` does, and neither where `a or b` fails.
        .both, .either => |sides| {
            if ((form == .both) != truth) return;
            try holds(c, file, out, sides[0], truth, use, since);
            try holds(c, file, out, sides[1], truth, use, since);
        },
        .compare => |compared| {
            const lhs = compared.left;
            const rhs = compared.right;
            const order = compared.order;
            // A compared `m[i]` was read: both sides are evaluated wherever the comparison's
            // truth is known.
            try read(c, file, out, lhs, use, since);
            try read(c, file, out, rhs, use, since);
            if (!try kept(c, file, lhs, since orelse compared.node, use) or !try kept(c, file, rhs, since orelse compared.node, use)) return;
            if (truth != (order == .equal) and (order == .equal or order == .not_equal)) {
                // Two values that differ: a position other than a length is below it where
                // another fact puts it at most the length.
                try out.append(c.allocator, .{ .small = lhs, .large = rhs, .strict = false, .differs = true });
            }
            const facts_of: []const Fact = switch (order) {
                .less => if (truth) &.{.{ .small = lhs, .large = rhs, .strict = true }} else &.{.{ .small = rhs, .large = lhs, .strict = false }},
                .less_or_equal => if (truth) &.{.{ .small = lhs, .large = rhs, .strict = false }} else &.{.{ .small = rhs, .large = lhs, .strict = true }},
                .greater => if (truth) &.{.{ .small = rhs, .large = lhs, .strict = true }} else &.{.{ .small = lhs, .large = rhs, .strict = false }},
                .greater_or_equal => if (truth) &.{.{ .small = rhs, .large = lhs, .strict = false }} else &.{.{ .small = lhs, .large = rhs, .strict = true }},
                .equal, .not_equal => if (truth == (order == .equal))
                    &.{ .{ .small = lhs, .large = rhs, .strict = false }, .{ .small = rhs, .large = lhs, .strict = false } }
                else if (literal(tree, rhs) == 0 and try unsignedAll(c, file, lhs))
                    // An unsigned value other than zero is at least one; a signed one may be
                    // below zero.
                    &.{.{ .small = rhs, .large = lhs, .strict = true }}
                else if (literal(tree, lhs) == 0 and try unsignedAll(c, file, rhs))
                    &.{.{ .small = lhs, .large = rhs, .strict = true }}
                else
                    &.{},
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
        .other => {},
    }
}

/// The comparison an aegis `bounded.Limit` check leaves where it passed: `try limit.check(n)`,
/// `limit.check(n) catch return …` and `if (limit.exceeds(n)) return …` put `n` at most the
/// limit, while nothing after assigns either.
fn limited(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
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
    if (call.ast.params.len != 1 or formAt(tree, call.ast.fn_expr) != .member) return;
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
    const tree = &c.project.at(file).file.tree;
    var value = statement;
    if (tree.fullVarDecl(statement)) |local| value = local.ast.init_node.unwrap() orelse return;
    const reservation = passed(tree, value) orelse return;
    // A charge by its callee's declared role (`Budget.reserve`), on the budget it is called on.
    const receiver = (try roleCall(c, file, reservation, .charge)) orelse return;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, reservation).?; // unreachable: roleCall found a call
    if (call.ast.params.len != 1) return;
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
    const tree = &c.project.at(file).file.tree;
    var at = bare(tree, amount);
    // A checked value's integer (`.raw()`, by its declared role): the value it is read from.
    if (try roleCall(c, file, at, .raw)) |holder| at = bare(tree, holder);
    if (constantOf(c, file, at)) |variable| at = bare(tree, variable.ast.init_node.unwrap() orelse return null);
    if (passed(tree, at)) |inner| at = bare(tree, inner);
    var buffer: [1]Ast.Node.Index = undefined;
    const step = tree.fullCall(&buffer, at) orelse return at;
    // A checked step that only grows (`.mul(n)`, `.add(n)`, by its declared role): `n` is at
    // most its result.
    _ = (try roleCall(c, file, at, .checked_growth)) orelse return null;
    if (step.ast.params.len != 1) return null;
    return step.ast.params[0];
}

/// The receiver of the method call `node`, where its callee is the one function aegis declares
/// with `role` (`Facts.calls`, PackageRules.role): null for any other call, a choice of callees,
/// or one called other than on a value.
fn roleCall(c: *Context, file: Project.FileId, node: Ast.Node.Index, role: Contract.Kind) Context.Error!?Ast.Node.Index {
    const call = (try Facts.calls.at(c.facts, file, node)) orelse return null;
    const function = switch (call.callee) {
        .function => |function| function,
        .choice, .any => return null,
    };
    if (try c.role(Contract.library, .{ .function = function }) != role) return null;
    return switch (call.receiver) {
        .bound => |receiver| receiver,
        else => null,
    };
}

/// The comparison a clamp leaves where it is done: `if (x > y) x = y;` puts `x` at most `y`
/// after it, and `if (x < y) x = y;` at least `y`, while nothing after assigns either.
fn clamped(c: *Context, file: Project.FileId, out: *std.ArrayList(Fact), branch: Ast.full.If, statement: Ast.Node.Index, use: Ast.Node.Index) Context.Error!void {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const statements: []const Ast.Node.Index = tree.blockStatements(&buffer, branch.ast.then_expr) orelse &.{branch.ast.then_expr};
    const compared = switch (Facts.conditionOf(tree, branch.ast.cond_expr)) {
        .compare => |found| switch (found.order) {
            .less, .less_or_equal, .greater, .greater_or_equal => found,
            .equal, .not_equal => return,
        },
        else => return,
    };
    // The clamp is the block's one assignment of a side of the condition to the other; the
    // block's other statements are assignments of neither (`n = r.at; status = .end_of_buffer;`).
    var clamp: ?Ast.Node.Index = null;
    for (statements) |statement_in| {
        if (formAt(tree, statement_in) != .assign) continue;
        const assigned_to = tree.nodeData(statement_in).node_and_node[0];
        if (!same(tree, assigned_to, compared.left) and !same(tree, assigned_to, compared.right)) continue;
        if (clamp != null) return;
        clamp = statement_in;
    }
    const then = clamp orelse return;
    for (statements) |other| {
        if (other == then) continue;
        const form = formAt(tree, other);
        if (form != .assign and form != .compound_assign) return;
        const lhs = tree.nodeData(other).node_and_node[0];
        if (same(tree, lhs, tree.nodeData(then).node_and_node[0]) or same(tree, lhs, tree.nodeData(then).node_and_node[1])) return;
    }
    const target, const value = tree.nodeData(then).node_and_node;
    const above, const under = switch (compared.order) {
        .greater, .greater_or_equal => .{ compared.left, compared.right },
        else => .{ compared.right, compared.left },
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
    const tree = &c.project.at(file).file.tree;
    if (literal(tree, compared) != null) return true;
    // An array compared is compared by its length, which is its type's: a store through a
    // pointer into it writes its elements, never that.
    if (try c.facts.resolve(file, compared) == .array) return true;
    if (try varies(c, file, compared)) return false;
    const from = tree.lastToken(condition);
    const to = tree.firstToken(use);
    if (to <= from) return true;
    const model = &c.project.at(file).model;
    // A loop's continue expression sits between its condition and its body but runs after the
    // body, before the condition is checked again: `while (i < n) : (i += 1) use(b[i])`.
    const skipped: ?Ast.Node.Index = loop: {
        var at = condition;
        while (model.parentOf(at)) |parent| : (at = parent) {
            const loop = tree.fullWhile(parent) orelse continue;
            if (loop.ast.cond_expr != at) break :loop null;
            const body_first = tree.firstToken(loop.ast.then_expr);
            if (to < body_first or to > tree.lastToken(loop.ast.then_expr)) break :loop null;
            break :loop loop.ast.cont_expr.unwrap();
        }
        break :loop null;
    };
    // The loops around the use the condition is outside of: their back edges.
    var around: aegis.bounded.Array(Ast.Node.Index, 8) = .init;
    if (also) |loop| around.appendSlice(&.{loop}) catch return false;
    {
        const guard = tree.firstToken(condition);
        var at = use;
        while (model.parentOf(at)) |parent| : (at = parent) {
            if (tree.nodeTag(parent) == .fn_decl) break;
            if (tree.fullWhile(parent) == null and tree.fullFor(parent) == null) continue;
            if (guard >= tree.firstToken(parent) and guard <= tree.lastToken(parent)) continue;
            // More loops than are kept: read as one around the whole function.
            around.appendSlice(&.{parent}) catch return false;
        }
    }
    const region: Region = .{ .tree = tree, .from = from, .to = to, .skipped = skipped, .loops = around.constItems() };
    // What the compared value reads, for the stores that reach it through other names.
    var places: Places = .{ .rename = try calleeReceiver(c, file, compared, condition) };
    try places.gather(c, file, compared, 0);
    const exposed = places.exposed();
    // Every token the region holds lies between the condition and the use or inside a loop
    // around the use: the nodes read are those of that span.
    var span_first = from;
    var span_last = to;
    for (around.constItems()) |loop| {
        span_first = @min(span_first, tree.firstToken(loop));
        span_last = @max(span_last, tree.lastToken(loop));
    }
    for (try actingWithin(c, file, span_first, span_last)) |node| {
        const form = accesses.formOf(tree.nodeTag(node));
        switch (form) {
            .assign, .compound_assign, .destructure => {
                if (!region.holds(tree.nodeMainToken(node)) or apart(c, file, node, use, condition)) continue;
                // A use inside the assignment is read before its store (`x &= x - 1`).
                if (region.before(node)) continue;
                const targets: []const Ast.Node.Index = if (form == .destructure) tree.assignDestructure(node).ast.variables else &.{tree.nodeData(node).node_and_node[0]};
                for (targets) |target| {
                    // `_ = x` discards: it stores nothing.
                    if (discards(tree, target)) continue;
                    if (reads(c, file, compared, target, 0) or try places.written(c, file, target)) return false;
                    if (exposed and try places.aliased(c, file, target)) return false;
                }
            },
            .@"asm" => {
                if (!region.holds(tree.nodeMainToken(node))) continue;
                // An output's or an input's own node is read with its `asm`.
                const full = tree.fullAsm(node) orelse continue;
                // An `asm` may write any memory a pointer reaches, and its outputs by name.
                if (exposed) return false;
                for (full.outputs) |output| {
                    const out_name = tree.nodeData(output).opt_node_and_token[1] - 1;
                    if (tree.tokenTag(out_name) != .identifier) continue;
                    const at = bare(tree, compared);
                    const last = tree.lastToken(at);
                    var k = tree.firstToken(at);
                    for (0..expression_tokens) |_| {
                        if (k > last) break;
                        if (std.mem.eql(u8, tree.tokenSlice(k), tree.tokenSlice(out_name))) return false;
                        k = std.math.add(Ast.TokenIndex, k, 1) catch return false;
                    } else return false;
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
            .call => {
                if (!region.holds(tree.nodeMainToken(node)) or apart(c, file, node, use, condition)) continue;
                if (region.before(node)) continue;
                if (exposed and !try inert(c, file, node)) return false;
            },
            .builtin => {
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

/// Whether a builtin writes memory a pointer it is given reaches, or calls (`@call`) a function
/// that may write any.
pub fn writesMemory(name: []const u8) bool {
    for ([_][]const u8{ "@memcpy", "@memset", "@memmove", "@atomicStore", "@atomicRmw", "@cmpxchgWeak", "@cmpxchgStrong", "@call" }) |writer| {
        if (std.mem.eql(u8, name, writer)) return true;
    }
    return false;
}

/// Whether an expression calls a function that may give another value each time: any but
/// std's `math.maxInt` and `math.minInt`, constants of the type they are given.
fn varies(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    for (try actingWithin(c, file, first, last)) |at| {
        if (accesses.formOf(tree.nodeTag(at)) != .call) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, at).?; // unreachable: a call's form holds calls
        const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
            .function => |d| d,
            .alternatives => return true,
            else => return true,
        };
        var constant_of_type = false;
        for ([_][]const u8{ "math.maxInt", "math.minInt" }) |path| {
            for (((try Governed.declarations(c, "std", path)).orNull()) orelse &.{}) |each| constant_of_type = constant_of_type or std.meta.eql(each, decl);
        }
        if (!constant_of_type) return true;
    }
    return false;
}

/// Whether a call cannot write the program's memory: a function of std's `mem`, `math`,
/// `ascii` or `unicode` namespaces, aegis's `assert` or std's `debug.assert` (`Pure`), which hold no pointer of the program's, whose parameters
/// can carry none it could write through: a type, a value of a primitive type, or a `const`
/// pointer or slice of one (a type parameter's where the call gives it a primitive type). A
/// function parameter, `anytype`, a struct by value or a mutable pointer may reach anything.
pub fn inert(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return false;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        .alternatives => return false,
        else => return false,
    };
    if (!try pure(c, decl)) return false;
    const callee = &c.project.at(decl.file).file.tree;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = callee.fullFnProto(&proto_buffer, c.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return false;
    // A method's receiver is its first parameter.
    var skip: usize = 0;
    if (formAt(tree, call.ast.fn_expr) == .member) switch (try c.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
        .instance, .pointer, .optional => skip = 1,
        // A choice may or may not hand a receiver first: which argument is not known.
        .alternatives => return false,
        else => {},
    };
    var it = proto.iterate(callee);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        const declared = param.type_expr orelse return false;
        var t = declared;
        if (formAt(callee, t) == .optional_type) t = callee.nodeData(t).node;
        if (callee.fullPtrType(t)) |pointer| {
            if (pointer.const_token == null) return false;
            t = pointer.ast.child_type;
        } else if (try c.facts.typeIsType(decl.file, t)) continue;
        if (!spellsName(callee, t)) return false;
        const name = callee.tokenSlice(callee.nodeMainToken(t));
        if (Model.primitive(name) and !std.mem.eql(u8, name, "anyopaque")) continue;
        // A type parameter's: the type the call gives it.
        const typed_at = (try typeParameter(c, decl.file, proto, name)) orelse return false;
        if (typed_at < skip) return false;
        const given = typed_at - skip;
        if (given >= call.ast.params.len) return false;
        const arg = call.ast.params[given];
        if (!spellsName(tree, arg) or !Model.primitive(tree.tokenSlice(tree.nodeMainToken(arg))) or std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(arg)), "anyopaque")) return false;
    }
    return true;
}

/// The position of the `comptime T: type` parameter named `name`.
fn typeParameter(c: *Context, file: Project.FileId, proto: Ast.full.FnProto, name: []const u8) Context.Error!?usize {
    const tree = &c.project.at(file).file.tree;
    var it = proto.iterate(tree);
    var index: usize = 0;
    while (it.next()) |param| : (index += 1) {
        const token = param.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token), name)) continue;
        const declared = param.type_expr orelse return null;
        if (!try c.facts.typeIsType(file, declared)) return null;
        return index;
    }
    return null;
}

/// The files of std's `mem`, `math`, `ascii` and `unicode` namespaces and of aegis's `assert`,
/// and the files they reach by their relative imports; and std's `debug.assert`, a function of
/// a truth value alone in a file that holds others. Found once for the run.
const Pure = struct { built: bool = false, files: std.AutoHashMapUnmanaged(u32, void) = .empty, checks: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty };

/// Whether `decl` is a function `inert` may read by its parameters: one of `Pure`'s.
fn pure(c: *Context, decl: Facts.Decl) Context.Error!bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Pure);
    if (!memo.built) {
        memo.built = true;
        const namespaces = [_][2][]const u8{ .{ "std", "mem" }, .{ "std", "math" }, .{ "std", "ascii" }, .{ "std", "unicode" }, .{ "aegis", "assert" } };
        for (namespaces) |namespace| {
            for (((try Governed.declarations(c, namespace[0], namespace[1])).orNull()) orelse &.{}) |found| {
                const value = try c.facts.declaration(((try c.facts.origin(found)).orNull()) orelse found);
                if (value != .container) continue;
                var next: std.ArrayList(Project.FileId) = .empty;
                if (!(try memo.files.getOrPut(c.allocator, @backingInt(value.container.file))).found_existing) try next.append(c.allocator, value.container.file);
                while (next.pop()) |at| for (c.project.imports) |mapping| {
                    if (mapping.from != at or !std.mem.endsWith(u8, mapping.spelling, ".zig")) continue;
                    if ((try memo.files.getOrPut(c.allocator, @backingInt(mapping.target))).found_existing) continue;
                    try next.append(c.allocator, mapping.target);
                };
            }
        }
        for (((try Governed.declarations(c, "std", "debug.assert")).orNull()) orelse &.{}) |found| try memo.checks.put(c.allocator, ((try c.facts.origin(found)).orNull()) orelse found, {});
    }
    return memo.files.contains(@backingInt(decl.file)) or memo.checks.contains(decl);
}

/// Whether a compared value reads what a store writes: the store's target spelled as a whole
/// part of it (`in` of `in.len`, `ip` of `ip + 1`, `s.buf` of `s.buf.len`; not `s.pos` of
/// `s.end`), or of the expression a constant it is names (`in_end` of `in.len - 32`).
fn reads(c: *Context, file: Project.FileId, compared: Ast.Node.Index, target: Ast.Node.Index, depth: u8) bool {
    const tree = &c.project.at(file).file.tree;
    const written_to = bare(tree, target);
    const want_first = tree.firstToken(written_to);
    const want_last = tree.lastToken(written_to);
    const at = bare(tree, compared);
    const last = tree.lastToken(at);
    // Each place a part may start, as long as the whole target fits before `last`.
    var start = tree.firstToken(at);
    for (0..expression_tokens) |_| {
        const span = std.math.sub(Ast.TokenIndex, want_last, want_first) catch return true;
        const end = std.math.add(Ast.TokenIndex, start, span) catch return true;
        if (end > last) break;
        defer start = std.math.add(Ast.TokenIndex, start, 1) catch last;
        // A part begins where no `.` names it a field of something else.
        if (start > 0 and tree.tokenTag(start - 1) == .period) continue;
        var a = start;
        var b = want_first;
        const alike = for (0..expression_tokens) |_| {
            if (tree.tokenTag(a) != tree.tokenTag(b) or !std.mem.eql(u8, tree.tokenSlice(a), tree.tokenSlice(b))) break false;
            if (b == want_last) break true;
            a = std.math.add(Ast.TokenIndex, a, 1) catch break false;
            b = std.math.add(Ast.TokenIndex, b, 1) catch break false;
        } else return true;
        if (!alike) continue;
        // And ends where nothing continues it but a field, an index or a call on it.
        if (end == last) return true;
        const next = std.math.add(Ast.TokenIndex, end, 1) catch return true;
        if (tree.tokenTag(next) != .identifier) return true;
    } else return true;
    if (constantOf(c, file, at)) |local| if (local.ast.init_node.unwrap()) |init| {
        // Past so many constants, what it reads is unknown: read as the target.
        if (depth >= 4) return true;
        return reads(c, file, init, target, depth + 1);
    };
    return false;
}

/// A place in memory an expression names: the declaration it starts at and the parts on the
/// way, a field by its name and any index as `[]` (`s.buf.len` is `s`, then `buf`, `len`).
/// Dereferences add no part, as a field reaches through a pointer alike.
const Place = struct {
    decl: Model.Declaration.Id,
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
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    // The parts come from the outside in; the eight nearest the declaration are kept.
    var parts: std.ArrayList([]const u8) = .empty;
    var exposed = false;
    // Whether a pointer is followed past the declaration's own step.
    var deep = false;
    var at = bare(tree, node);
    // An array's length, or that of an array behind a pointer, is its type's: no store or
    // pointer writes it.
    if (try c.facts.lengthOf(file, at)) |memory| {
        switch (try c.facts.resolve(file, memory)) {
            .array => return null,
            .pointer => |inner| if (inner.child.* == .array) return null,
            // A choice may hold memory whose length is written: read as a place.
            .alternatives => {},
            else => {},
        }
    }
    for (0..expression_tokens) |_| {
        const form = formAt(tree, at);
        if (form == .leaf) break;
        const part: ?[]const u8, const inner = switch (form) {
            .member => .{ tree.tokenSlice(tree.nodeData(at).node_and_token[1]), tree.nodeData(at).node_and_token[0] },
            .array_access => .{ "[]", tree.nodeData(at).node_and_node[0] },
            .unwrap_optional => .{ null, tree.nodeData(at).node_and_token[0] },
            .deref => .{ null, tree.nodeData(at).node },
            else => return null,
        };
        const follows = switch (form) {
            .member => try fieldFollows(c, file, at, inner),
            .array_access => (try c.facts.resolve(file, inner)) != .array,
            .deref => true,
            else => false,
        };
        if (follows) {
            exposed = true;
            if (nameRef(model, bare(tree, inner)) == null) deep = true;
        }
        if (part) |name| try parts.append(c.allocator, name);
        at = bare(tree, inner);
    } else return null;
    const d = (nameRef(model, at) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    const scope = model.scopes[@backingInt(record.scope)].kind;
    if (record.kind == .variable and (scope == .file or scope == .container)) exposed = true;
    if (!exposed and try addressed(c, file, d)) exposed = true;
    var out: Place = .{ .decl = d, .exposed = exposed };
    std.mem.reverse([]const u8, parts.items);
    for (parts.items, 0..) |part, i| {
        if (i >= out.parts.len) break;
        out.parts[i] = part;
        out.len += 1;
    }
    out.flat = !deep and out.len > 0 and !std.mem.eql(u8, out.parts[0], "[]") and try structured(c, file, at);
    return out;
}

/// Whether reading the field `name` of `receiver` follows a pointer: a single pointer's field
/// does, a slice's `len` and `ptr` do not (unless what it points to has a field of the name),
/// and a field of a container named as a namespace is a container-level variable's. A receiver
/// the reading does not know may be either: read as following one.
fn fieldFollows(c: *Context, file: Project.FileId, access: Ast.Node.Index, receiver: Ast.Node.Index) Context.Error!bool {
    const name = c.project.at(file).file.tree.tokenSlice(c.project.at(file).file.tree.nodeData(access).node_and_token[1]);
    return switch (try c.facts.resolve(file, receiver)) {
        .pointer => |inner| blk: {
            if (try c.facts.languageField(file, access) == .none) break :blk true;
            break :blk switch (inner.child.*) {
                .instance, .container => |k| c.facts.member(k, name) != null,
                // A pointer to a pointer is a slice of pointers or a single pointer to a slice
                // (`p: *[]const u8`), whose `len` is read through it.
                .pointer => true,
                .primitive, .array, .optional, .scalar => false,
                .alternatives => true,
                else => true,
            };
        },
        .instance, .array, .literal, .reified, .primitive, .scalar, .error_union, .optional, .error_set, .function, .fn_type => false,
        .alternatives => true,
        else => true,
    };
}

/// Whether a declaration's value is a struct (not a union), or a single pointer to one.
fn structured(c: *Context, file: Project.FileId, root: Ast.Node.Index) Context.Error!bool {
    var value = try c.facts.resolve(file, root);
    if (value == .pointer) value = value.pointer.child.*;
    const k = switch (value) {
        .instance => |k| k,
        .alternatives => return false,
        else => return false,
    };
    const tree = &c.project.at(k.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const declared = tree.fullContainerDecl(&buffer, c.project.at(k.file).model.scopes[@backingInt(k.scope)].node) orelse return false;
    return tree.tokenTag(declared.ast.main_token) == .keyword_struct;
}

/// Whether a declaration may be written by another name, as `Facts.accesses` finds its writes:
/// its address taken (`&x`, `&x.f`, a slice of an array), a method whose receiver is a pointer
/// called on it, a capture binding a pointer into it (`if (x) |*p|`), or memory code the program
/// does not hold writes (an `asm` output naming it, an `extern`). Found once per declaration.
///
/// Kept for the run whoever asked first and on whatever budget, which is sound by how the
/// writes are found, not by this memo: `Facts.accesses` walks each file's syntax whole (a
/// walk that fails keeps nothing, `writesOf`), and a target or a holder it cannot resolve, for
/// want of budget as for any other reason, is itself a site of every place it may name (`open`,
/// `covered`, a member on a holder that does not resolve). A cut can only add sites, and a
/// site this reads as addressed; none ends the scan with "not addressed".
const Addressed = struct { map: std.AutoHashMapUnmanaged(struct { Project.FileId, Model.Declaration.Id }, bool) = .empty };

/// Whether the memory `memory` names may hold a length no build checks: one written in place
/// (`s.len = n`, `@field(s, "len") = n`, of it or of memory it holds), or written by another
/// name for it (its address taken). Such a length is any `usize`.
fn lengthWritten(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    // An array's length is its type's.
    if (try c.facts.resolve(file, memory) == .array) return false;
    const d = rootOf(tree, model, memory) orelse return false;
    if (try addressed(c, file, d)) return true;
    var in_file: [1]Project.FileId = undefined;
    var found_sites = try declarationWrites(c, file, d, &in_file);
    while (try found_sites.next()) |site| {
        // A program the unit is read for may write any part of it.
        if (site.kind == .open) return true;
        if (!site.part or site.kind == .init) continue;
        const target = site.target orelse continue;
        if (try writesLength(c, site.file, target)) return true;
    }
    return false;
}

/// Whether a store into `target` may write a length: a slice's own `len` (`Facts.languageField`),
/// or a holder's that does not resolve; `@field(holder, name)` with a name that may be it.
fn writesLength(c: *Context, file: Project.FileId, target: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    if (formAt(tree, target) == .member) return switch (try c.facts.languageField(file, target)) {
        .len, .unknown => true,
        .ptr, .none => false,
    };
    if (!Facts.isBuiltin(tree, target, "@field")) return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, target, &buffer);
    if (args.len != 2) return true;
    return c.facts.mayName(try c.facts.fieldName(file, args[1]), "len");
}

fn addressed(c: *Context, file: Project.FileId, d: Model.Declaration.Id) Context.Error!bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const memo = try c.facts.memo(Addressed);
    const key = .{ file, d };
    if (memo.map.get(key)) |known| return known;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var in_file: [1]Project.FileId = undefined;
    var found_sites = try declarationWrites(c, file, d, &in_file);
    const found = while (try found_sites.next()) |site| switch (site.kind) {
        // An address discarded (`_ = &x;`) reaches nothing.
        .address => if (!discarded(tree, model, site.node)) break true,
        // A program the unit is read for may write it.
        .covered, .open => break true,
        else => {},
    } else false;
    try memo.map.put(c.allocator, key, found);
    return found;
}

/// Whether a value is discarded: `_ = value;`.
fn discarded(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const parent = model.parentOf(node) orelse return false;
    if (formAt(tree, parent) != .assign) return false;
    const target, const value = tree.nodeData(parent).node_and_node;
    return value == node and discards(tree, target);
}

/// The declaration an expression names memory of, past fields, indexes and unwraps but not a
/// dereference: `x` of `x.f[i]`, none of `p.*`.
fn rootOf(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Model.Declaration.Id {
    var at = node;
    while (true) switch (formAt(tree, at)) {
        .leaf => return (nameRef(model, at) orelse return null).declaration,
        .member, .unwrap_optional, .grouped => at = tree.nodeData(at).node_and_token[0],
        .array_access => at = tree.nodeData(at).node_and_node[0],
        .slice => at = (tree.fullSlice(at) orelse return null).ast.sliced,
        else => return null,
    };
}

/// A declaration read as another: a callee's receiver parameter as the receiver its call names.
const Rename = struct { from: Model.Declaration.Id, to: Model.Declaration.Id };

/// Where `compared` is a callee's condition read at its call `since` (`succeeded`): the callee's
/// first parameter, which it is rooted at, as the local or parameter the call names as its
/// receiver, spelled the same. Null for anything else.
fn calleeReceiver(c: *Context, file: Project.FileId, compared: Ast.Node.Index, since: Ast.Node.Index) Context.Error!?Rename {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, since) orelse return null;
    if (formAt(tree, call.ast.fn_expr) != .member) return null;
    const receiver = tree.nodeData(call.ast.fn_expr).node_and_token[0];
    const to = (nameRef(model, receiver) orelse return null).declaration orelse return null;
    const from = rootOf(tree, model, bare(tree, compared)) orelse return null;
    if (from == to) return null;
    const record = model.declarations[@backingInt(from)];
    if (record.kind != .parameter or !std.mem.eql(u8, record.name, model.declarations[@backingInt(to)].name)) return null;
    // The parameter is the first of the function the call reaches.
    const callee = try c.facts.resolve(file, call.ast.fn_expr);
    if (callee != .function or callee.function.file != file) return null;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&proto_buffer, model.declarations[@backingInt(callee.function.index)].node) orelse return null;
    var parameters = proto.iterate(tree);
    const first = parameters.next() orelse return null;
    if (first.name_token != record.token) return null;
    return .{ .from = from, .to = to };
}

/// The places a compared value reads: each named in it, and those of the constants it names.
const Places = struct {
    items: [8]Place = undefined,
    len: u8 = 0,
    /// More places than are kept: read as exposed.
    over: bool = false,
    /// A callee's receiver read as its call's (`calleeReceiver`).
    rename: ?Rename = null,

    fn add(self: *Places, given: Place) void {
        var place = given;
        if (self.rename) |r| if (place.decl == r.from) {
            place.decl = r.to;
        };
        if (self.len == self.items.len) {
            self.over = true;
            return;
        }
        self.items[self.len] = place;
        self.len += 1;
    }

    fn gather(self: *Places, c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!void {
        // Past so many parts, the places left out may be written by any name.
        if (depth >= 4) {
            self.over = true;
            return;
        }
        const tree = &c.project.at(file).file.tree;
        const at = bare(tree, node);
        if (try placeOf(c, file, at)) |place| {
            self.add(place);
            if (constantOf(c, file, at)) |local| if (local.ast.init_node.unwrap()) |init| try self.gather(c, file, init, depth + 1);
        }
        switch (formAt(tree, at)) {
            .operator => if (accesses.operatorOf(tree.nodeTag(at)) != null) {
                const lhs, const rhs = tree.nodeData(at).node_and_node;
                try self.gather(c, file, lhs, depth + 1);
                try self.gather(c, file, rhs, depth + 1);
            },
            .array_access => try self.gather(c, file, tree.nodeData(at).node_and_node[1], depth + 1),
            .builtin => {
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
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const token = tree.firstToken(use);
    const inside = struct {
        fn range(t: *const Ast, node: Ast.Node.Index, at: Ast.TokenIndex) bool {
            return at >= t.firstToken(node) and at <= t.lastToken(node);
        }
    }.range;
    var at = assignment;
    while (model.parentOf(at)) |parent| : (at = parent) {
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
        while (model.parentOf(around)) |outer| : (around = outer) {
            if (tree.nodeTag(outer) == .fn_decl) break;
            if ((tree.fullWhile(outer) != null or tree.fullFor(outer) != null) and !inside(tree, outer, guard)) return false;
        }
        return true;
    }
    return false;
}

/// The bound a fact gives its smaller side: the larger side's, one less where it is strictly
/// under it.
fn below(c: *Context, file: Project.FileId, fact: Fact, pointer: u16, depth: u8) Context.Error!?Magnitude {
    const most = (try bound(c, file, fact.large, pointer, depth)) orelse return null;
    return if (fact.strict) most -| 1 else most;
}

/// Whether a difference `lhs - rhs` cannot go below zero: a comparison that holds there puts
/// `rhs` at most `lhs` (or a literal `rhs` at most what `lhs` is known to be at least), `rhs`
/// is a position into the memory whose length `lhs` is, or a literal `lhs` is at least all an
/// unsigned `rhs` can be.
fn ordered(c: *Context, file: Project.FileId, node: Ast.Node.Index, lhs: Ast.Node.Index, rhs: Ast.Node.Index, pointer: u16) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    if (literal(tree, rhs) == 0) return true;
    // A literal less what is known to be at most it (`8 - bit % 8`).
    if (literal(tree, lhs)) |k| {
        if (try nonnegative(c, file, rhs, pointer)) if (try bound(c, file, rhs, pointer, 0)) |most| if (most <= k) return true;
    }
    if (try c.facts.lengthOf(file, lhs)) |memory| if (try indexes(c, file, rhs, memory)) return true;
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
        if (Facts.isBuiltin(tree, call, "@min") and try kept(c, file, lhs, call, node)) {
            var buffer: [2]Ast.Node.Index = undefined;
            for (Facts.builtinArgs(tree, call, &buffer)) |arg| if (try ordered(c, file, node, lhs, arg, pointer)) return true;
        }
    };
    const taken = literal(tree, rhs);
    // One taken from what is above zero (`(@as(u128, 1) << k) - 1`).
    if (taken == 1 and try nonnegative(c, file, lhs, pointer) and try nonzero(c, file, lhs)) return true;
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
    const tree = &c.project.at(file).file.tree;
    if (tree.nodeTag(rhs) != .mul) return null;
    const a, const b = tree.nodeData(rhs).node_and_node;
    for ([_][2]Ast.Node.Index{ .{ a, b }, .{ b, a } }) |pair| {
        const quotient_node, const k = pair;
        const ref = nameRef(&c.project.at(file).model, quotient_node) orelse continue;
        const init = (try untyped(c, .{ .file = file, .index = ref.declaration orelse continue })) orelse continue;
        const y: Ast.Node.Index, const by: Ast.Node.Index = if (checkedOp(tree, init) == .div) tree.nodeData(init).node_and_node else blk: {
            if (!Facts.isBuiltin(tree, init, "@divFloor") and !Facts.isBuiltin(tree, init, "@divTrunc")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, init, &buffer);
            if (args.len != 2) continue;
            break :blk .{ args[0], args[1] };
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

/// Per file, the nodes a bound's proof looks for (an index or a slice, a call or a builtin's,
/// a store, an address taken, an `asm`) in source order by main token, found once for the run: syntax
/// alone, so the same whoever asks and whatever budget is left. `indexes`, `varies` and
/// `keptAcross` are asked at every bound of every summary; a scan of the file's nodes for each
/// made their cost the file's size times the bounds asked.
const Acting = struct { by_file: std.AutoHashMapUnmanaged(Project.FileId, []const Ast.Node.Index) = .empty };

/// `acting`'s nodes whose main token lies in `first..last`, both ends included.
fn actingWithin(c: *Context, file: Project.FileId, first: Ast.TokenIndex, last: Ast.TokenIndex) Context.Error![]const Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const sites = try acting(c, file);
    var low: usize = 0;
    var high: usize = sites.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (tree.nodeMainToken(sites[mid]) < first) low = mid + 1 else high = mid;
    }
    var end = low;
    while (end < sites.len and tree.nodeMainToken(sites[end]) <= last) end += 1;
    return sites[low..end];
}

fn acting(c: *Context, file: Project.FileId) Context.Error![]const Ast.Node.Index {
    if ((try c.facts.memo(Acting)).by_file.get(file)) |known| return known;
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const tree = &c.project.at(file).file.tree;
    // Ordered by counting each token's nodes, then placing each node after those of the tokens
    // before its own: no comparison, so no call the run cannot follow.
    const starts = try c.allocator.alloc(usize, tree.tokens.len + 1);
    defer c.allocator.free(starts);
    @memset(starts, 0);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (acts(tag)) starts[tree.nodeMainToken(@fromBackingInt(@intCast(i))) + 1] += 1;
    }
    for (starts[1..], starts[0 .. starts.len - 1]) |*next, before| next.* += before;
    const found = try c.allocator.alloc(Ast.Node.Index, starts[starts.len - 1]);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (!acts(tag)) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        found[starts[token]] = node;
        starts[token] += 1;
    }
    try (try c.facts.memo(Acting)).by_file.put(c.allocator, file, found);
    return found;
}

/// Whether a node of this tag is one `acting` lists.
fn acts(tag: Ast.Node.Tag) bool {
    return switch (accesses.formOf(tag)) {
        .array_access, .slice, .call, .builtin, .assign, .compound_assign, .destructure, .address_of, .@"asm" => true,
        else => false,
    };
}

/// Whether the function holding `node` indexes or slices memory with it (`memory` alone,
/// where given).
fn indexes(c: *Context, file: Project.FileId, node: Ast.Node.Index, memory: ?Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const function = found: {
        var up: ?Ast.Node.Index = node;
        while (up) |each| : (up = model.parentOf(each)) if (tree.nodeTag(each) == .fn_decl) break :found each;
        return false;
    };
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (try actingWithin(c, file, first, last)) |at| {
        const form = accesses.formOf(tree.nodeTag(at));
        if (form != .array_access and form != .slice) continue;
        const into, const bounds: [2]?Ast.Node.Index = if (form == .array_access) blk: {
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
fn alias(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    if (try captured(c, file, bare(tree, node))) |search| return search;
    const variable = constantOf(c, file, bare(tree, node)) orelse return null;
    if (try searched(c, file, variable.ast.init_node.unwrap() orelse return null)) |search| return search;
    const init = bare(tree, variable.ast.init_node.unwrap() orelse return null);
    var base = init;
    while (formAt(tree, base) == .member) base = tree.nodeData(base).node_and_token[0];
    const ref = nameRef(&c.project.at(file).model, base) orelse return null;
    const d = ref.declaration orelse return null;
    const kind = c.project.at(file).model.declarations[@backingInt(d)].kind;
    if (kind != .parameter and constantOf(c, file, base) == null) return null;
    return init;
}

/// The search a capture names: `|x|` of `while (search) |x|` or `if (search) |x|`, the call's
/// value unwrapped.
fn captured(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const d = (nameRef(model, node) orelse return null).declaration orelse return null;
    if (model.declarations[@backingInt(d)].kind != .capture) return null;
    const owner = model.declarations[@backingInt(d)].node;
    const condition = if (tree.fullWhile(owner)) |loop| loop.ast.cond_expr else if (tree.fullIf(owner)) |branch| branch.ast.cond_expr else return null;
    return searched(c, file, condition);
}

/// The constant local an identifier names.
fn constantOf(c: *Context, file: Project.FileId, node: Ast.Node.Index) ?Ast.full.VarDecl {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const d = (nameRef(model, node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
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
    var at = Facts.ungrouped(tree, node);
    while (true) {
        var buffer: [2]Ast.Node.Index = undefined;
        if (formAt(tree, at) != .builtin) return at;
        const args = Facts.builtinArgs(tree, at, &buffer);
        at = Facts.ungrouped(tree, if (Facts.isBuiltin(tree, at, "@as") and args.len == 2) args[1] else if (Facts.isBuiltin(tree, at, "@intCast") and args.len == 1) args[0] else return at);
    }
}

/// Whether the comparisons holding where `index` is read keep it within `memory`: below its
/// length (`if (i >= buf.len) return`), or, as a slice's end, at most it; or below a fixed
/// array's declared length. Such a position the program has checked, and no peer's choice
/// of it reaches past the memory.
pub fn within(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    // A bound read through another bound reads that one's facts in turn: so deep and no deeper.
    const nesting = try c.facts.memo(Nesting);
    if (nesting.level >= 16) return false;
    nesting.level += 1;
    defer nesting.level -= 1;
    return withinOnce(c, file, index, memory, end);
}

/// How deep `within` is in reading itself.
const Nesting = struct { level: u8 = 0 };

fn withinOnce(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    // A remainder by the memory's length is below it (a zero length stops the remainder), and
    // so is a `for` counter over its length or beside it.
    if (try remainderOf(c, file, index, memory)) return true;
    if (try counted(c, file, index, memory)) return true;
    // A least of several (`@min(x, m.len - 1)`) is at most each: one within is enough; and the
    // length less what cannot be zero is below it (where it would go under zero it stops).
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, index);
    // A slice's end at the memory's own length.
    if (end and try lengthOf(c, file, at, memory) and !try varies(c, file, memory)) return true;
    if (checkedOp(tree, at) == .sub) {
        const whole, const taken = tree.nodeData(at).node_and_node;
        const kept_above = for (widths(c)) |pointer| {
            if (!try nonnegative(c, file, taken, pointer)) break false;
        } else true;
        if (try lengthOf(c, file, whole, memory) and !try varies(c, file, memory) and (end or try nonzero(c, file, taken))) {
            if (kept_above) return true;
        }
        // Less what is not below zero is at most what it is taken from: within where that is
        // (where it would go under zero it stops, A010's).
        if (kept_above and try within(c, file, whole, memory, end)) return true;
    }
    // A constant local is its value, while the memory stays as it was where it was given.
    if (constantOf(c, file, at)) |local| if (local.ast.init_node.unwrap()) |init| {
        if (try within(c, file, init, memory, end) and try kept(c, file, memory, init, index)) return true;
    };
    if (Facts.isBuiltin(tree, at, "@min")) {
        var buffer: [2]Ast.Node.Index = undefined;
        for (Facts.builtinArgs(tree, at, &buffer)) |arg| if (try within(c, file, arg, memory, end)) return true;
    }
    const held_here = try gather(c, file, index);
    for (widths(c)) |pointer| {
        // A fixed array's length is known: a bound below it is enough, and otherwise the
        // comparisons with its length are read as a slice's.
        if (try fixedLength(c, file, memory)) |n| if (try bound(c, file, index, pointer, 0)) |most| {
            if (if (end) most <= n else most < n) continue;
        };
        if (!try keeps(c, file, held_here, index, memory, end)) return false;
    }
    return true;
}

/// Whether `index` is a table's own id read as its integer, `t[@backingInt(id)]` (`ownIndex`).
/// Such a position names an entry where no make of the id that is not shown to count the
/// table's entries reaches it: Taint's `uncounted_id` fact decides that at each site (A009's
/// index and slice sinks), and each such make is judged where it is written. The type does not
/// tell which table of that element: an id of one table read in another of the same element, or
/// in one the program has shrunk since, is the program's to keep apart.
pub fn ownTable(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    return (try ownIndex(c, file, index, memory)) != null;
}

/// The container whose own id `index` reads as its integer to index its table: `index` is
/// `@backingInt(id)` or `@intFromEnum(id)`, `id`'s type is an id the container declares
/// (`ownerOf`), and `memory` holds that container's values (`[]T`, `[N]T`, `*[N]T`).
fn ownIndex(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!?Facts.Container {
    return switch (try indexOwner(c, file, index, memory)) {
        .owner => |owner| owner,
        // A position whose id or memory does not resolve is no table's own here: nothing
        // clears it by its table.
        .none, .unknown => null,
    };
}

/// `ownIndex`, telling a position that is no table's own from one whose id or memory does not
/// resolve: the second may be any table's, which the run's list of tables has to say
/// (`TableIds.open`).
const IndexOwner = union(enum) { owner: Facts.Container, none, unknown };

fn indexOwner(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!IndexOwner {
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, index);
    if (!Facts.isBuiltin(tree, at, "@backingInt") and !Facts.isBuiltin(tree, at, "@intFromEnum")) return .none;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, at, &buffer);
    if (args.len != 1) return .none;
    const id = switch (try c.facts.resolve(file, args[0])) {
        .instance => |k| k,
        // A choice of types, or a type that does not resolve, may be an id.
        .alternatives, .unknown => return .unknown,
        else => return .none,
    };
    const owner = ownerOf(c, id) orelse return .none;
    var entries = try c.facts.resolve(file, memory);
    if (entries == .pointer) entries = entries.pointer.child.*;
    if (entries == .array) entries = entries.array.*;
    return switch (entries) {
        .instance => |k| if (owner.file == k.file and owner.scope == k.scope) .{ .owner = owner } else .none,
        // Memory that does not resolve may hold the owner's values.
        .alternatives, .unknown => .unknown,
        else => .none,
    };
}

/// The run's table ids: the containers whose ids index a table of their values somewhere in the
/// program (`ownIndex`).
const TableIds = struct {
    /// The list itself, which owns its storage: what is read of it is its items.
    indexed: ?std.ArrayList(Facts.Container) = null,
    /// Whether a position in the program reads an id as its integer where the id or the memory
    /// does not resolve (`IndexOwner.unknown`), a resolution the budget cut short among them:
    /// the list may then miss a table, so every id a container declares counts as one
    /// (`isTable`). A table missed would leave its id's makes uncounted and clear its positions.
    open: bool = false,
};

/// The containers whose own ids index a table of their values somewhere in the program.
fn tableOwners(c: *Context) Context.Error![]const Facts.Container {
    const memo = try c.facts.memo(TableIds);
    if (memo.indexed) |known| return known.items;
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    var found: std.ArrayList(Facts.Container) = .empty;
    for (c.project.sources) |*source| {
        const file = source.id;
        if (!try Program.owns(c, file)) continue;
        const tree = &source.file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (Facts.accesses.formOf(tag) != .array_access) continue;
            const memory, const index = tree.nodeData(@fromBackingInt(@intCast(i))).node_and_node;
            const owner = switch (try indexOwner(c, file, index, memory)) {
                .owner => |owner| owner,
                .none => continue,
                .unknown => {
                    memo.open = true;
                    continue;
                },
            };
            for (found.items) |known| {
                if (known.file == owner.file and known.scope == owner.scope) break;
            } else try found.append(c.allocator, owner);
        }
    }
    memo.indexed = found;
    return found.items;
}

/// Whether `owner`'s ids index a table of its values somewhere in the program.
fn isTable(c: *Context, owner: Facts.Container) Context.Error!bool {
    for (try tableOwners(c)) |known| if (known.file == owner.file and known.scope == owner.scope) return true;
    return (try c.facts.memo(TableIds)).open;
}

/// Whether `call` makes a table's own id other than by counting the table's entries: a
/// `@fromBackingInt` or `@enumFromInt` making one whose operand `countsEntries` does not show
/// within, a `@bitCast` or `@ptrCast` making one, or a conversion whose type does not resolve
/// where the program has such ids (`madeOf`), whichever file it is in: std's generics make the
/// program's ids where the program binds them to one. The source of Taint's `uncounted_id` fact. A
/// make in test code is none: a test's ids reach no proof of the program's own.
pub fn uncountedMake(c: *Context, file: Project.FileId, call: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const counts = Facts.isBuiltin(tree, call, "@fromBackingInt") or Facts.isBuiltin(tree, call, "@enumFromInt");
    if (!counts and !Facts.isBuiltin(tree, call, "@bitCast") and !Facts.isBuiltin(tree, call, "@ptrCast")) return false;
    if (try c.inTestCodeOf(file, tree.nodeMainToken(call))) return false;
    return switch (try madeOf(c, file, call, !counts)) {
        .other => false,
        .unknown => true,
        .id => |owner| !counts or !try countsEntries(c, file, call, owner),
    };
}

/// How a make forges a table's own id (`forgeries`): bits taken from other data.
pub const Form = enum {
    /// A conversion making the id itself, or a cast to it or to a pointer to it
    /// (`uncountedMake`): what Taint's `uncounted_id` fact starts at.
    conversion,
    /// A `@bitCast` to a type that holds one.
    bits,
    /// A `@ptrCast`, `@ptrFromInt` or `@extern` to a pointer to memory that holds one, read as
    /// that type from now on.
    cast_to,
    /// A `@ptrCast` of a pointer to memory that holds one to another type: what is written
    /// through the result writes the id.
    cast_from,
    /// A union without a tag (bare, `extern`, `packed`) with a member that holds one: a store
    /// to another member is read as it.
    overlay,
    /// An `extern` function or variable, or an exported function, whose types hold one: code
    /// the run does not read makes it.
    foreign,
    /// An `asm` whose output holds one.
    assembly,
};

/// One make that may forge `of`'s id, or any table's (none): where it is written and how.
pub const Forgery = struct {
    file: Project.FileId,
    node: Ast.Node.Index,
    of: ?Facts.Container,
    form: Form,
    /// For one of any id: only of an id declared outside the program. Code outside the program
    /// names the program's types only where the program binds them (a generic's reading), so
    /// what does not resolve there, in no generic, is no type of the program's.
    outside: bool = false,
};

const Forgeries = struct { read: ?[]const Forgery = null };

/// The table ids a type holds, in its own memory or behind a pointer it holds: `any` where a
/// part of it does not resolve.
const Held = struct {
    any: bool = false,
    /// Any id declared outside the program (`Forgery.outside`).
    outside: bool = false,
    owners: std.ArrayList(Facts.Container) = .empty,

    fn add(ids: *Held, c: *Context, owner: Facts.Container) Context.Error!void {
        for (ids.owners.items) |known| if (known.file == owner.file and known.scope == owner.scope) return;
        try ids.owners.append(c.allocator, owner);
    }
};

/// The table ids `value`, a type or a value of it, holds, into `ids` (`Held`).
fn holders(c: *Context, value: Facts.Value, ids: *Held, seen: *std.ArrayList(Facts.Container), depth: usize) Context.Error!void {
    if (ids.any) return;
    if (depth > 64) {
        ids.any = true;
        return;
    }
    switch (value) {
        // What this build does not compile, and Zig's own per-build values, hold none of the
        // program's types.
        .unknown => |why| if (why != .absent and why != .zig_own) {
            ids.any = true;
        },
        .primitive, .scalar, .error_set, .function, .fn_type => {},
        .pointer => |pointer| try holders(c, pointer.child.*, ids, seen, depth + 1),
        .array, .optional, .error_union => |inner| try holders(c, inner.*, ids, seen, depth + 1),
        .alternatives => |each| for (each) |one| try holders(c, one, ids, seen, depth + 1),
        .reified => |built| try holders(c, built.fields.*, ids, seen, depth + 1),
        .reflected, .literal => {
            ids.any = true;
        },
        .container, .instance => |k| {
            if (ownerOf(c, k)) |owner| {
                if (try isTable(c, owner)) try ids.add(c, owner);
                return;
            }
            for (seen.items) |known| if (known.file == k.file and known.scope == k.scope and known.made_by == k.made_by) return;
            try seen.append(c.allocator, k);
            for (try c.facts.fieldsOf(k)) |index| try holders(c, try c.facts.memberOf(k, .{ .file = k.file, .index = index }), ids, seen, depth + 1);
        },
    }
}

/// What a conversion's result is read into, as a type or a value of it, under `outer`: unknown
/// where nothing names it, a number where it is another conversion's backing integer.
fn readInto(c: *Context, file: Project.FileId, node: Ast.Node.Index, outer: ?*const Facts.Env) Context.Error!Facts.Value {
    return switch ((try destined(c, file, node, outer)) orelse return .{ .unknown = .unresolved }) {
        .named => |type_node| try typeNamed(c, type_node, outer),
        .assigned => |lhs| if (outer) |env| try c.facts.resolveBound(env, file, lhs) else try c.facts.resolve(file, lhs),
        .field => |decl| try c.facts.declaration(decl),
        .backing, .shifted => .scalar,
    };
}

/// The memory a pointer points at, an array's element for the array: what a cast between two
/// pointers to it leaves as it is. None for what is no pointer.
fn pointee(value: Facts.Value) ?Facts.Value {
    var at = value;
    while (at == .optional) at = at.optional.*;
    if (at != .pointer) return null;
    at = at.pointer.child.*;
    while (at == .array) at = at.array.*;
    return at;
}

/// Whether two pointers point at memory of one type: a cast between them changes the pointer's
/// size or qualifiers alone.
fn oneMemory(a: Facts.Value, b: Facts.Value) bool {
    const from = pointee(a) orelse return false;
    const to = pointee(b) orelse return false;
    return switch (from) {
        .container, .instance => |k| switch (to) {
            .container, .instance => |other| k.file == other.file and k.scope == other.scope and k.made_by == other.made_by and k.symbolic == other.symbolic,
            // A choice may be another type: the cast counts.
            .alternatives => false,
            else => false,
        },
        .primitive => |name| to == .primitive and std.mem.eql(u8, name, to.primitive),
        .alternatives => false,
        else => false,
    };
}

const Site = struct { file: Project.FileId, node: Ast.Node.Index, form: Form };

/// What the make at `site` holds in one reading of the function it is in (none: as written).
fn heldIn(c: *Context, site: Site, outer: ?*const Facts.Env, ids: *Held) Context.Error!void {
    const tree = &c.project.at(site.file).file.tree;
    var seen: std.ArrayList(Facts.Container) = .empty;
    switch (site.form) {
        .conversion, .overlay, .foreign => unreachable, // unreachable: `forgeries` reads these where they are written
        .bits, .cast_to => try holders(c, try readInto(c, site.file, site.node, outer), ids, &seen, 0),
        .cast_from => {
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, site.node, &buffer);
            if (args.len == 0) return;
            var operand = Facts.ungrouped(tree, args[args.len - 1]);
            // A cast of alignment or qualifiers hands on the pointer it is given.
            while (formAt(tree, operand) == .builtin and leavesType(tree.tokenSlice(tree.nodeMainToken(operand)))) {
                var inner: [2]Ast.Node.Index = undefined;
                const given = Facts.builtinArgs(tree, operand, &inner);
                if (given.len == 0) break;
                operand = Facts.ungrouped(tree, given[given.len - 1]);
            }
            const from = if (outer) |env| try c.facts.resolveBound(env, site.file, operand) else try c.facts.resolve(site.file, operand);
            if (oneMemory(from, try readInto(c, site.file, site.node, outer))) return;
            try holders(c, from, ids, &seen, 0);
        },
        .assembly => {
            const full = tree.fullAsm(site.node) orelse return;
            for (full.outputs) |output| {
                const type_node = tree.nodeData(output).opt_node_and_token[0].unwrap() orelse continue;
                try holders(c, if (outer) |env| try c.facts.resolveBound(env, site.file, type_node) else try c.facts.resolve(site.file, type_node), ids, &seen, 0);
            }
        },
    }
}

/// What the make at `site` holds: as written where that resolves, else in each reading the run
/// compiles its function in. A generic nothing compiled binds holds nothing; a reading that
/// cannot be made, or a make at a container's level that does not resolve, may hold any.
/// Memory `std.mem.Allocator`'s own functions hand out or take back holds no value yet, so a
/// cast there, or in a function only they bind in that reading, forges nothing.
fn heldAt(c: *Context, site: Site, ids: *Held) Context.Error!void {
    const raw = try allocatorFile(c);
    if (raw == site.file) return;
    var direct: Held = .{};
    try heldIn(c, site, null, &direct);
    if (!direct.any) {
        for (direct.owners.items) |owner| try ids.add(c, owner);
        return;
    }
    if (try unbound(c, site.file, site.node)) {
        for (direct.owners.items) |owner| try ids.add(c, owner);
        ids.outside = true;
        return;
    }
    const function = c.facts.functionHolding(site.file, site.node) orelse {
        ids.any = true;
        return;
    };
    const readings = (try c.facts.instantiatedReadings(function)) orelse {
        ids.any = true;
        return;
    };
    for (readings) |reading| {
        const env = reading orelse {
            ids.any = true;
            return;
        };
        if (raw) |hands_out| if (try c.facts.boundOnlyFrom(function, env, hands_out)) continue;
        try heldIn(c, site, env, ids);
    }
}

/// Whether `node` is written outside the program and in no generic: in no function Zig
/// analyzes once per instantiation (`Facts.instantiated`). What does not resolve there is no
/// type of the program's (`Forgery.outside`).
fn unbound(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    if (try Program.owns(c, file)) return false;
    const function = c.facts.functionHolding(file, node) orelse return true;
    return !c.facts.instantiated(function);
}

/// The file that is `std.mem.Allocator`, by its declaration; none where the run has none or
/// its declaration does not resolve.
fn allocatorFile(c: *Context) Context.Error!?Project.FileId {
    const declared = switch (try Governed.declarations(c, "std", "mem.Allocator")) {
        .decls => |decls| decls,
        // No allocator in the run, or one that does not resolve: no file's memory is read as
        // handed out, so every cast there counts.
        .none, .unknown => return null,
    };
    for (declared) |each| {
        switch (try c.facts.declaration(each)) {
            .container => |k| if (c.project.at(k.file).model.scopes[@backingInt(k.scope)].kind == .file) return k.file,
            // A choice names no one file: no memory is read as the allocator's.
            .alternatives => {},
            else => {},
        }
    }
    return null;
}

/// Every make in what the run reads, std as the program, that may forge a table's own id
/// (`Form`): the run's answer by type, where the flow to a position does not tell (`sealed`).
/// A value of an id's type comes only from a make, so a type none of these names holds only
/// ids counted over its table. This holds for initialized memory: `undefined` and memory
/// `std.mem.Allocator` hands out hold no value yet and make none, and a read of either before
/// a write is A019's. A make in test code is none.
pub fn forgeries(c: *Context) Context.Error![]const Forgery {
    const memo = try c.facts.memo(Forgeries);
    if (memo.read) |known| return known;
    // What it keeps in its memo stays for the run.
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    var found: std.ArrayList(Forgery) = .empty;
    if (try declaresIds(c)) for (c.project.sources) |*source| {
        const file = source.id;
        const tree = &source.file.tree;
        for (0..tree.nodes.len) |i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            var ids: Held = .{};
            var form: Form = undefined;
            switch (formAt(tree, node)) {
                .builtin => {
                    const name = tree.tokenSlice(tree.nodeMainToken(node));
                    const counts = std.mem.eql(u8, name, "@fromBackingInt") or std.mem.eql(u8, name, "@enumFromInt");
                    const bits = std.mem.eql(u8, name, "@bitCast");
                    const cast = std.mem.eql(u8, name, "@ptrCast");
                    if (!counts and !bits and !cast and !std.mem.eql(u8, name, "@ptrFromInt") and !std.mem.eql(u8, name, "@extern")) continue;
                    if (try c.inTestCodeOf(file, tree.nodeMainToken(node))) continue;
                    if ((counts or bits or cast) and try uncountedMake(c, file, node)) {
                        const of: ?Facts.Container = switch (try madeOf(c, file, node, !counts)) {
                            .id => |owner| owner,
                            .other, .unknown => null,
                        };
                        try found.append(c.allocator, .{ .file = file, .node = node, .form = .conversion, .of = of, .outside = of == null and try unbound(c, file, node) });
                        if (counts) continue;
                    }
                    if (counts) continue;
                    form = if (bits) .bits else .cast_to;
                    try heldAt(c, .{ .file = file, .node = node, .form = form }, &ids);
                    if (cast) {
                        try note(c, &found, file, node, form, ids);
                        ids = .{};
                        form = .cast_from;
                        try heldAt(c, .{ .file = file, .node = node, .form = form }, &ids);
                    }
                },
                .@"asm" => {
                    if (tree.fullAsm(node) == null or try c.inTestCodeOf(file, tree.nodeMainToken(node))) continue;
                    form = .assembly;
                    try heldAt(c, .{ .file = file, .node = node, .form = form }, &ids);
                },
                else => {
                    var buffer: [2]Ast.Node.Index = undefined;
                    var seen: std.ArrayList(Facts.Container) = .empty;
                    if (tree.fullContainerDecl(&buffer, node)) |declared| {
                        if (tree.tokenTag(declared.ast.main_token) != .keyword_union) continue;
                        if (declared.layout_token == null and (declared.ast.enum_token != null or declared.ast.arg != .none)) continue;
                        if (try c.inTestCodeOf(file, declared.ast.main_token)) continue;
                        form = .overlay;
                        for (source.model.declarations) |decl| {
                            if (decl.kind != .field or source.model.scopes[@backingInt(decl.scope)].node != node) continue;
                            const field_type = (source.model.containerField(tree, decl.node) orelse continue).ast.type_expr.unwrap() orelse continue;
                            try holders(c, try c.facts.resolve(file, field_type), &ids, &seen, 0);
                        }
                        try settle(c, file, node, &ids);
                    } else if (tree.fullFnProto(buffer[0..1], node)) |proto| {
                        const token = proto.extern_export_inline_token orelse continue;
                        if (tree.tokenTag(token) != .keyword_extern and tree.tokenTag(token) != .keyword_export) continue;
                        form = .foreign;
                        if (proto.ast.return_type.unwrap()) |result| try holders(c, try c.facts.resolve(file, result), &ids, &seen, 0);
                        var it = proto.iterate(tree);
                        while (it.next()) |param| if (param.type_expr) |type_node| try holders(c, try c.facts.resolve(file, type_node), &ids, &seen, 0);
                        try settle(c, file, node, &ids);
                    } else if (tree.fullVarDecl(node)) |variable| {
                        const token = variable.extern_export_token orelse continue;
                        if (tree.tokenTag(token) != .keyword_extern) continue;
                        form = .foreign;
                        try holders(c, try c.facts.resolve(file, variable.ast.type_node.unwrap() orelse continue), &ids, &seen, 0);
                        try settle(c, file, node, &ids);
                    } else continue;
                },
            }
            try note(c, &found, file, node, form, ids);
        }
    };
    const makes = try found.toOwnedSlice(c.allocator);
    memo.read = makes;
    return makes;
}

/// A declaration's types read as written: what does not resolve outside the program, in no
/// generic, is none of the program's (`unbound`).
fn settle(c: *Context, file: Project.FileId, node: Ast.Node.Index, ids: *Held) Context.Error!void {
    if (!ids.any or !try unbound(c, file, node)) return;
    ids.any = false;
    ids.outside = true;
}

/// Each id `ids` names as a forgery at `node`, or one of any id.
fn note(c: *Context, found: *std.ArrayList(Forgery), file: Project.FileId, node: Ast.Node.Index, form: Form, ids: Held) Context.Error!void {
    if (ids.any) return found.append(c.allocator, .{ .file = file, .node = node, .form = form, .of = null });
    if (ids.outside) try found.append(c.allocator, .{ .file = file, .node = node, .form = form, .of = null, .outside = true });
    for (ids.owners.items) |owner| try found.append(c.allocator, .{ .file = file, .node = node, .form = form, .of = owner });
}

/// Whether the id positioning `memory` at `index` (`ownTable`) is of a type nothing in the run
/// may forge (`forgeries`); with `beyond_flow`, nothing but the conversions Taint's
/// `uncounted_id` fact follows to each position.
pub fn sealed(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, beyond_flow: bool) Context.Error!bool {
    const owner = (try ownIndex(c, file, index, memory)) orelse return false;
    for (try forgeries(c)) |each| {
        if (beyond_flow and each.form == .conversion) continue;
        const of = each.of orelse {
            if (each.outside and try Program.owns(c, owner.file)) continue;
            return false;
        };
        if (of.file == owner.file and of.scope == owner.scope) return false;
    }
    return true;
}

/// Whether a make the flow of values does not follow (any form but a conversion) names the id
/// positioning `memory` at `index` by its own table: an overlay, a cast of memory that holds
/// it, a foreign declaration. Where input goes through one, no fact of the value tells.
pub fn forged(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    const owner = (try ownIndex(c, file, index, memory)) orelse return false;
    for (try forgeries(c)) |each| {
        if (each.form == .conversion) continue;
        const of = each.of orelse continue;
        if (of.file == owner.file and of.scope == owner.scope) return true;
    }
    return false;
}

/// The container whose own id `id` may be, by its structure alone: `id` is an enum with a
/// backing integer whose one member is `_` (no named value, so none is made without a
/// conversion), declared directly in that container, whatever it is named. Only a candidate:
/// what clears an index on it is that no uncounted make reaches it (`ownTable`).
fn ownerOf(c: *Context, id: Facts.Container) ?Facts.Container {
    if (id.made_by != null or id.symbolic) return null;
    const tree = &c.project.at(id.file).file.tree;
    const model = &c.project.at(id.file).model;
    const scope = model.scopes[@backingInt(id.scope)];
    if (scope.kind != .container) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const declared = tree.fullContainerDecl(&buffer, scope.node) orelse return null;
    if (tree.tokenTag(declared.ast.main_token) != .keyword_enum or declared.ast.arg == .none) return null;
    var open = false;
    for (declared.ast.members) |member| {
        const each = model.containerField(tree, member) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(each.ast.main_token), "_")) return null;
        open = true;
    }
    if (!open) return null;
    const holder = scope.parent orelse return null;
    if (model.scopes[@backingInt(holder)].kind != .container) return null;
    return .{ .file = id.file, .scope = holder };
}

/// The element of memory indexed by position: a slice's or many-item pointer's, an array's,
/// or the array's a pointer to one points at.
fn elementOf(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Context.Error!?Facts.Container {
    var value = try c.facts.resolve(file, memory);
    if (value == .pointer) value = value.pointer.child.*;
    if (value == .array) value = value.array.*;
    return switch (value) {
        .instance => |k| k,
        .alternatives => null,
        else => null,
    };
}

/// What a `@fromBackingInt` or `@enumFromInt` makes, as A009 reads it: a table's own id (the
/// container whose `Id` it is), another type, or a type the place its result is read into
/// does not name.
pub const Made = union(enum) { id: Facts.Container, other, unknown };

pub fn madeId(c: *Context, file: Project.FileId, call: Ast.Node.Index) Context.Error!Made {
    return madeOf(c, file, call, false);
}

/// What the conversion `call` makes (`madeId`); through a pointer where `pointed` (`@ptrCast`
/// to a pointer to an id). An id is a table's only where its ids index a table of their
/// container (`isTable`).
fn madeOf(c: *Context, file: Project.FileId, call: Ast.Node.Index, pointed: bool) Context.Error!Made {
    const direct = try madeIn(c, file, call, pointed, null);
    if (direct != .unknown) return direct;
    // A type only a binding decides: what each binding the run compiles makes it. One of a
    // generic nothing compiled binds makes nothing; one that does not resolve stays unknown.
    const function = c.facts.functionHolding(file, call) orelse return .unknown;
    for ((try c.facts.instantiatedReadings(function)) orelse return .unknown) |reading| {
        const made = try madeIn(c, file, call, pointed, reading orelse return .unknown);
        if (made != .other) return made;
    }
    return .other;
}

/// `madeOf` under `outer`, one reading of the function the conversion is in (none, as written).
fn madeIn(c: *Context, file: Project.FileId, call: Ast.Node.Index, pointed: bool, outer: ?*const Facts.Env) Context.Error!Made {
    var made = switch ((try destined(c, file, call, outer)) orelse return .unknown) {
        .named => |type_node| try typeNamed(c, type_node, outer),
        .assigned => |lhs| if (outer) |env| try c.facts.resolveBound(env, file, lhs) else try c.facts.resolve(file, lhs),
        .field => |decl| try c.facts.declaration(decl),
        .backing, .shifted => return .other,
    };
    while (made == .optional or (pointed and made == .pointer)) made = if (made == .optional) made.optional.* else made.pointer.child.*;
    return switch (made) {
        .container, .instance => |k| if (ownerOf(c, k)) |owner| (if (try isTable(c, owner)) .{ .id = owner } else .other) else .other,
        .unknown => if (try declaresIds(c)) .unknown else .other,
        // A choice may hold a table's id: not known.
        .alternatives => .unknown,
        else => .other,
    };
}

/// Whether a conversion making `owner`'s id counts the entries of a table of `owner`: its
/// operand is shown within that table when it is made, and a table whose ids are kept only
/// grows. As a `for` counter over it (`for (t, 0..) |_, i|`), its length less what cannot be
/// zero (`t.len - 1`, after an append), or below the length of a table of `owner`'s entries the
/// function names, by what `within` reads there (`if (n >= t.len) return error.Malformed;`
/// before `@fromBackingInt(n)`).
pub fn countsEntries(c: *Context, file: Project.FileId, call: Ast.Node.Index, owner: Facts.Container) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, call, &buffer);
    if (args.len != 1) return false;
    const operand = bare(tree, args[0]);
    if (checkedOp(tree, operand) == .sub) {
        const table = (try c.facts.lengthOf(file, bare(tree, tree.nodeData(operand).node_and_node[0]))) orelse return false;
        if (try entriesOf(c, file, table, owner) and try within(c, file, args[0], table, false)) return true;
    } else if (try counterOver(c, file, operand, owner)) return true;
    return belowTable(c, file, call, args[0], owner);
}

/// Whether `operand` is a counter from zero beside a table of `owner`'s entries taken first
/// (`for (t, 0..) |_, i|`): below its length when the loop began.
fn counterOver(c: *Context, file: Project.FileId, operand: Ast.Node.Index, owner: Facts.Container) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const d = (nameRef(model, operand) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(d)];
    if (record.kind != .capture) return false;
    const loop = tree.fullFor(record.node) orelse return false;
    const taken = Model.capturePosition(tree, loop, record.token) orelse return false;
    if (taken == 0 or taken >= loop.ast.inputs.len or tree.nodeTag(loop.ast.inputs[taken]) != .for_range) return false;
    const start, const end = tree.nodeData(loop.ast.inputs[taken]).node_and_opt_node;
    if (literal(tree, start) != 0 or end != .none) return false;
    return entriesOf(c, file, loop.ast.inputs[0], owner);
}

/// Whether `operand`, made into `owner`'s id at `call`, is shown within a table of `owner`'s
/// entries the enclosing function names by its length (`t.len`) or loops over (`for (t)`):
/// each such table is asked of `within` at the operand.
fn belowTable(c: *Context, file: Project.FileId, call: Ast.Node.Index, operand: Ast.Node.Index, owner: Facts.Container) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    var function = call;
    while (formAt(tree, function) != .fn_decl) function = model.parentOf(function) orelse return false;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const table: Ast.Node.Index = switch (accesses.formOf(tag)) {
            .member => (try c.facts.lengthOf(file, node)) orelse continue,
            .@"for" => tree.fullFor(node).?.ast.inputs[0], // unreachable: the form is a for's
            else => continue,
        };
        if (tree.firstToken(node) < first or tree.lastToken(node) > last) continue;
        if (!try entriesOf(c, file, table, owner)) continue;
        if (try within(c, file, operand, table, false)) return true;
    }
    return false;
}

/// Whether `table` is memory of `owner`'s entries.
fn entriesOf(c: *Context, file: Project.FileId, table: Ast.Node.Index, owner: Facts.Container) Context.Error!bool {
    const entries = (try elementOf(c, file, table)) orelse return false;
    return entries.file == owner.file and entries.scope == owner.scope;
}

/// Whether the program has a table's own id (`tableOwners`): where none does, a conversion whose
/// type does not resolve makes none.
pub fn declaresIds(c: *Context) Context.Error!bool {
    return (try tableOwners(c)).len != 0 or (try c.facts.memo(TableIds)).open;
}

/// Whether `index` is a remainder by `memory`'s length of a value at zero or above: `x %
/// m.len`, `@mod(x, m.len)`, `@rem(x, m.len)`.
fn remainderOf(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, index);
    const dividend: Ast.Node.Index, const divisor: Ast.Node.Index = if (checkedOp(tree, at) == .mod) tree.nodeData(at).node_and_node else blk: {
        if (!Facts.isBuiltin(tree, at, "@mod") and !Facts.isBuiltin(tree, at, "@rem")) return false;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, at, &buffer);
        if (args.len != 2) return false;
        break :blk .{ args[0], args[1] };
    };
    if (!try lengthOf(c, file, divisor, memory) or try varies(c, file, memory)) return false;
    for (widths(c)) |pointer| if (!try nonnegative(c, file, dividend, pointer)) return false;
    return true;
}

/// Whether `index` is a `for` loop's counter below `memory`'s length, its range ending there
/// (`for (0..m.len) |i|`) or the loop taking `memory` first beside it (`for (m, 0..) |x, i|`),
/// and nothing in the loop changes the memory: its inputs are read once, before every pass.
fn counted(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const at = bare(tree, index);
    const d = (nameRef(model, at) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(d)];
    if (record.kind != .capture) return false;
    const loop = tree.fullFor(record.node) orelse return false;
    const taken = Model.capturePosition(tree, loop, record.token) orelse return false;
    if (taken >= loop.ast.inputs.len or tree.nodeTag(loop.ast.inputs[taken]) != .for_range) return false;
    const start, const end = tree.nodeData(loop.ast.inputs[taken]).node_and_opt_node;
    if (literal(tree, start) != 0) return false;
    // The loop runs as many passes as its first input has elements; Zig checks the others
    // match only where safety is on.
    const bounded = if (end.unwrap()) |e| try lengthOf(c, file, e, memory) else same(tree, loop.ast.inputs[0], memory);
    if (!bounded or try varies(c, file, memory)) return false;
    return keptAcross(c, file, memory, loop.ast.inputs[loop.ast.inputs.len - 1], index, record.node);
}

/// Whether a slice's start is at most its end: a start of zero; an end that adds to the start
/// (`b[i .. i + n]`, where the sum cannot wrap); an end at the memory's own length with the
/// start within it; `b[e - n .. e]` where the difference cannot underflow; or a comparison
/// holding there puts the start at most the end (`if (at >= t.size) return null;` before
/// `b[at..t.size]`). Both bounds within the memory say nothing of their order (`b[i..n]` with
/// `i <= b.len` and `n <= b.len`): a start past the end stops the program as surely as one
/// past the memory.
pub fn notAfter(c: *Context, file: Project.FileId, start: Ast.Node.Index, end: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, start);
    const least = literal(tree, at);
    if (least == 0) return true;
    // An end a constant names is its value (`const id_end = 1 + @as(usize, n);`).
    var last = bare(tree, end);
    for (0..4) |_| {
        const local = constantOf(c, file, last) orelse break;
        last = bare(tree, local.ast.init_node.unwrap() orelse break);
    }
    switch (tree.nodeTag(last)) {
        // An unsigned sum is at least each part: the start itself, or a constant at least it.
        .add, .add_sat => {
            const lhs, const rhs = tree.nodeData(last).node_and_node;
            if (try oneValue(c, file, lhs, start) or try oneValue(c, file, rhs, start)) return true;
            if (least) |k| if ((literal(tree, lhs) orelse literal(tree, rhs) orelse 0) >= k) return true;
        },
        else => {},
    }
    if (try lengthOf(c, file, last, memory) and !try varies(c, file, memory) and try within(c, file, start, memory, true)) return true;
    if (tree.nodeTag(at) == .sub) {
        const lhs, const rhs = tree.nodeData(at).node_and_node;
        if (try oneValue(c, file, lhs, end)) {
            for (widths(c)) |pointer| if (!try ordered(c, file, at, lhs, rhs, pointer)) return false;
            return true;
        }
    }
    for (try facts(c, file, start)) |fact| {
        // Two values that differ are in no order, and a read puts a position below a memory.
        if (fact.differs or fact.read) continue;
        if (try oneValue(c, file, fact.small, start) and try oneValue(c, file, fact.large, end)) return true;
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
    const tree = &c.project.at(file).file.tree;
    const index_base, const j = shift(tree, index);
    // `index_base + most` is at most the length.
    var most: ?i128 = null;
    for (held_here) |fact| {
        if (fact.differs) continue;
        if (try covered(c, file, fact, index, memory, end)) return true;
        // One step through a bound that is itself within the memory: `n <= e` and `e` at most
        // its length (a read's count and the end of the one buffer it filled).
        if (!fact.read and try oneValue(c, file, fact.small, index) and try within(c, file, fact.large, memory, end or fact.strict) and try kept(c, file, memory, fact.large, index)) return true;
        if (fact.read) {
            if (!same(tree, fact.large, memory)) continue;
            const base, const k = shift(tree, fact.small);
            const step: i128 = @intFromBool(fact.strict);
            if (try oneValue(c, file, base, index_base)) {
                const reach = std.math.add(i128, k, step) catch return false;
                most = @max(most orelse reach, reach);
            }
            continue;
        }
        if (try lengthOf(c, file, fact.large, memory)) {
            const base, const k = shift(tree, fact.small);
            const step: i128 = @intFromBool(fact.strict);
            if (try oneValue(c, file, base, index_base)) {
                const reach = std.math.add(i128, k, step) catch return false;
                most = @max(most orelse reach, reach);
            }
            continue;
        }
        if (try remains(c, file, fact, index, memory, end)) return true;
        // One step through another fact: `a <= b` and `b <= length`.
        for (held_here) |next| {
            if (next.differs or next.read or !try lengthOf(c, file, next.large, memory) or !try oneValue(c, file, fact.large, next.small)) continue;
            const base, const k = shift(tree, fact.small);
            const step: i128 = @as(i128, @intFromBool(fact.strict)) + @intFromBool(next.strict);
            if (try oneValue(c, file, base, index_base)) {
                const reach = std.math.add(i128, k, step) catch return false;
                most = @max(most orelse reach, reach);
            }
        }
    }
    var m = most orelse return false;
    // `index_base + m` at most the length and other than it: below it.
    var moved = true;
    while (moved) {
        moved = false;
        for (held_here) |fact| {
            if (!fact.differs) continue;
            const spot = if (try lengthOf(c, file, fact.large, memory)) fact.small else if (try lengthOf(c, file, fact.small, memory)) fact.large else continue;
            const base, const k = shift(tree, spot);
            if (k == m and try oneValue(c, file, base, index_base)) {
                m = std.math.add(i128, m, 1) catch return false;
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
    const tree = &c.project.at(file).file.tree;
    var needed: Terms = .{};
    var base = bare(tree, memory);
    while (openSlice(tree, base)) |slice| {
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
        if (!try lengthOf(c, file, whole_length, base)) return false;
        whole.constant = std.math.add(i128, whole.constant, k) catch return false;
    } else if (!try lengthOf(c, file, fact.large, base)) return false;
    if (!try whole.add(c, file, fact.small, 0) or whole.len == 0 or (whole.len < 2 and whole.constant == 0)) return false;
    var used: [Terms.capacity]bool = @splat(false);
    for (needed.nodes[0..needed.len]) |term| {
        for (whole.nodes[0..whole.len], 0..) |part, i| {
            if (used[i] or !try oneValue(c, file, part, term)) continue;
            used[i] = true;
            break;
        } else return false;
    }
    for (whole.nodes[0..whole.len], used[0..whole.len]) |part, taken| if (!taken) {
        const typed = try typeOf(c, file, part, 64, 0);
        if (typed != .int or typed.int.signed) return false;
    };
    const room = std.math.sub(i128, std.math.add(i128, whole.constant, @intFromBool(fact.strict)) catch return false, needed.constant) catch return false;
    return if (end) room >= 0 else room >= 1;
}

/// The argument a call passes through unchanged: a function of one parameter each of whose
/// returns is that parameter, or an `asm` with an empty template whose one output is tied
/// (`"0"`) to its one input, the parameter, as an optimization barrier is (warp's
/// `chainless(ip + 3)` is `ip + 3`).
fn identity(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (call.ast.params.len != 1) return null;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |d| d,
        .alternatives => return null,
        else => return null,
    };
    const model = &c.project.at(decl.file).model;
    const callee = &c.project.at(decl.file).file.tree;
    const proto_node = model.declarations[@backingInt(decl.index)].node;
    var proto_buffer: [1]Ast.Node.Index = undefined;
    const proto = callee.fullFnProto(&proto_buffer, proto_node) orelse return null;
    var params = proto.iterate(callee);
    const param = params.next() orelse return null;
    if (params.next() != null) return null;
    const name = callee.tokenSlice(param.name_token orelse return null);
    const fn_decl = model.parentOf(proto_node) orelse return null;
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
    if (spellsName(tree, at)) return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(at)), name);
    if (formAt(tree, at) == .@"switch") {
        const full = tree.fullSwitch(at).?; // unreachable: a switch's form holds switches
        for (full.ast.cases) |case| if (!passes(tree, tree.fullSwitchCase(case).?.ast.target_expr, name, depth + 1)) return false;
        return true;
    }
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
    return spellsName(tree, operand) and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(operand)), name);
}

fn valueOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!?u64 {
    if (depth > 4) return null;
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, node);
    if (literal(tree, at)) |k| return k;
    if (checkedOp(tree, at)) |op| {
        const lhs, const rhs = tree.nodeData(at).node_and_node;
        if (op != .add and op != .sub and op != .mul and op != .shl) return null;
        const a = (try valueOf(c, file, lhs, depth + 1)) orelse return null;
        const b = (try valueOf(c, file, rhs, depth + 1)) orelse return null;
        return switch (op) {
            .add => std.math.add(u64, a, b) catch null,
            .sub => std.math.sub(u64, a, b) catch null,
            .mul => std.math.mul(u64, a, b) catch null,
            // `1 << 16`: exact, or none where bits would be lost.
            else => std.math.shlExact(u64, a, std.math.cast(u6, b) orelse return null) catch null,
        };
    }
    if (nameRef(&c.project.at(file).model, at) == null and formAt(tree, at) != .member) return null;
    const decl = ((try c.facts.definition(file, at)).orNull()) orelse return null;
    const model = &c.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    if (record.kind != .variable) return null;
    const declared = &c.project.at(decl.file).file.tree;
    const variable = declared.fullVarDecl(record.node) orelse return null;
    if (declared.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    return valueOf(c, decl.file, variable.ast.init_node.unwrap() orelse return null, depth + 1);
}

/// A sum as its parts and the constants added in it: `6 + l1 + l2` is `l1`, `l2` and 6, and
/// a constant naming a sum is that sum (`const records_at = id_end + 4;`).
const Terms = struct {
    const capacity = 8;
    nodes: [capacity]Ast.Node.Index = undefined,
    len: usize = 0,
    constant: i128 = 0,

    fn add(terms: *Terms, c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: u8) Context.Error!bool {
        const tree = &c.project.at(file).file.tree;
        const at = bare(tree, node);
        if (try valueOf(c, file, at, 0)) |k| {
            terms.constant = std.math.add(i128, terms.constant, k) catch return false;
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
                terms.constant = std.math.sub(i128, terms.constant, k) catch return false;
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
fn remains(c: *Context, file: Project.FileId, fact: Fact, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const large = bare(tree, fact.large);
    if (tree.nodeTag(large) != .sub) return false;
    const whole, const taken = tree.nodeData(large).node_and_node;
    if (!try lengthOf(c, file, whole, memory) or !try oneValue(c, file, index, taken)) return false;
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

/// Whether `a` and `b` are one value: spelled alike, or one a constant local naming the other, or
/// holding the call the other is (only a read fact names an impure call: one that varies is never
/// kept).
fn oneValue(c: *Context, file: Project.FileId, a: Ast.Node.Index, b: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    if (same(tree, a, b)) return true;
    if (try alias(c, file, a)) |x| if (same(tree, x, b)) return true;
    if (try alias(c, file, b)) |y| if (same(tree, a, y)) return true;
    // A constant holding a call's value is that call where a fact names it (a read's count).
    if (constantOf(c, file, bare(tree, a))) |local| if (givenCall(tree, local.ast.init_node.unwrap() orelse return false)) |x| if (same(tree, x, b)) return true;
    if (constantOf(c, file, bare(tree, b))) |local| if (givenCall(tree, local.ast.init_node.unwrap() orelse return false)) |y| if (same(tree, a, y)) return true;
    return false;
}

/// Whether `node` is `memory.len`, or `m.len - a` where `memory` is `m[a..]`, or a constant
/// local naming one.
fn lengthOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(file).file.tree;
    const at = bare(tree, node);
    // The length an array's type spells (`out: *[width]u8`, `var r: [width]u8`), which the
    // compiler fixes: the same names read the same comptime values wherever they are visible.
    if (declaredLength(c, file, memory)) |declared| if (same(tree, declared, at)) return true;
    if (checkedOp(tree, at) == .sub) {
        const slice = openSlice(tree, bare(tree, memory)) orelse return false;
        const whole, const start = tree.nodeData(at).node_and_node;
        return same(tree, start, slice.ast.start) and try lengthOf(c, file, whole, slice.ast.sliced);
    }
    if (nameRef(&c.project.at(file).model, at) != null) {
        const named_value = (try alias(c, file, at)) orelse return false;
        return lengthOf(c, file, named_value, memory);
    }
    const receiver = (try c.facts.lengthOf(file, at)) orelse return false;
    return same(tree, receiver, memory);
}

/// The length expression of the array `memory` names, as its declaration's type spells it, in
/// this file: a local's or a parameter's `[n]T` or `*[n]T`, or a `for` capture's over a literal
/// whose elements are all addresses of such arrays of one spelled length (`inline for (.{ &r,
/// &s }) |out|`). Only names and their fields: what an array type's length names is comptime.
fn declaredLength(c: *Context, file: Project.FileId, memory: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    const at = bare(tree, memory);
    const d = (nameRef(model, at) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    const type_node: Ast.Node.Index = switch (record.kind) {
        .variable => (tree.fullVarDecl(record.node) orelse return null).ast.type_node.unwrap() orelse return null,
        .parameter => c.facts.parameterTypeNode(.{ .file = file, .index = d }) orelse return null,
        .capture => {
            const loop = tree.fullFor(record.node) orelse return null;
            // The input the capture walks: captures name the inputs in order.
            var token = loop.payload_token;
            var input: usize = 0;
            while (token < record.token) : (token += 1) {
                if (tree.tokenTag(token) == .comma) input += 1;
            }
            if (input >= loop.ast.inputs.len) return null;
            return commonLength(c, file, loop.ast.inputs[input]);
        },
        else => return null,
    };
    return arrayLength(tree, type_node);
}

/// The length every element of a tuple or array literal of array addresses spells alike.
fn commonLength(c: *Context, file: Project.FileId, literal_node: Ast.Node.Index) ?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const elements: []const Ast.Node.Index = if (tree.fullArrayInit(&buffer, literal_node)) |each| each.ast.elements else return null;
    var found: ?Ast.Node.Index = null;
    for (elements) |item| {
        if (formAt(tree, item) != .address_of) return null;
        const spelled = declaredLength(c, file, tree.nodeData(item).node) orelse return null;
        if (found) |first| {
            if (!same(tree, first, spelled)) return null;
        } else found = spelled;
    }
    return found;
}

/// The length an array type spells, through one single-item pointer to it: `n` of `[n]T`,
/// `*[n]T` and their sentinel forms, where `n` is names and fields alone.
fn arrayLength(tree: *const Ast, type_node: Ast.Node.Index) ?Ast.Node.Index {
    var t = type_node;
    if (tree.fullPtrType(t)) |pointer| {
        if (pointer.size != .one) return null;
        t = pointer.ast.child_type;
    }
    const spelled = (tree.fullArrayType(t) orelse return null).ast.elem_count;
    var part = spelled;
    while (formAt(tree, part) == .member) part = tree.nodeData(part).node_and_token[0];
    return if (spellsName(tree, part)) spelled else null;
}

/// Which way a bound holds a value: at most it, or at least it.
pub const Side = enum { ceiling, floor };

/// What the comparisons holding where `at` is evaluated put `value` at most (`.ceiling`: the
/// larger sides) or at least (`.floor`: the smaller sides), `value` spelled as they spell it.
pub fn boundsAt(c: *Context, file: Project.FileId, at: Ast.Node.Index, value: Ast.Node.Index, side: Side) Context.Error![]const Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var out: std.ArrayList(Ast.Node.Index) = .empty;
    for (try facts(c, file, at)) |fact| switch (side) {
        .ceiling => if (same(tree, fact.small, value)) try out.append(c.allocator, fact.large),
        .floor => if (same(tree, fact.large, value)) try out.append(c.allocator, fact.small),
    };
    return out.items;
}

/// The argument whose value a call's result keeps, at most: std's `Io.Limit.limited(n)` and
/// `limited64(n)`, a limit of `n` (the latter at most `maxInt(usize)`), by their declarations.
/// Null where the callee is none of them, or std's `Io.Limit` does not resolve.
pub fn keptArgument(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (call.ast.params.len != 1) return null;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |decl| decl,
        .alternatives => return null,
        else => return null,
    };
    for ([_][]const u8{ "Io.Limit.limited", "Io.Limit.limited64" }) |path| switch (try Governed.declarations(c, "std", path)) {
        .decls => |decls| for (decls) |each| if (each.file == decl.file and each.index == decl.index) return call.ast.params[0],
        .none, .unknown => {},
    };
    return null;
}

/// The parameter of the call `node` whose value its result's length is, the receiver first:
/// std's `Io.Reader.take(r, n)` and `peek(r, n)`, which give `n` bytes or fail, by their
/// declarations. Null where the callee is neither, or std's reader does not resolve.
pub fn lengthArgument(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?usize {
    const tree = &c.project.at(file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    const decl = switch (try c.facts.resolve(file, call.ast.fn_expr)) {
        .function => |decl| decl,
        .alternatives => return null,
        else => return null,
    };
    for ([_][]const u8{ "Io.Reader.take", "Io.Reader.peek" }) |path| switch (try Governed.declarations(c, "std", path)) {
        .decls => |decls| for (decls) |each| if (each.file == decl.file and each.index == decl.index) return 1,
        .none, .unknown => {},
    };
    return null;
}

/// What the comparisons holding where `node` is read put it at most: the larger sides, for a
/// sink that asks whether one is the program's own limit.
pub fn ceilings(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error![]const Ast.Node.Index {
    const tree = &c.project.at(file).file.tree;
    var out: std.ArrayList(Ast.Node.Index) = .empty;
    for (try facts(c, file, node)) |fact| if (same(tree, fact.small, node)) try out.append(c.allocator, fact.large);
    return out.items;
}

/// Whether a value is std's `mem.Allocator`.
fn allocator(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    var value_of = try c.facts.resolve(file, node);
    if (value_of == .pointer) value_of = value_of.pointer.child.*;
    const k = switch (value_of) {
        .instance => |k| k,
        .alternatives => return false,
        else => return false,
    };
    for (((try Governed.declarations(c, "std", "mem.Allocator")).orNull()) orelse return false) |decl| {
        const value = try c.facts.declaration(((try c.facts.origin(decl)).orNull()) orelse decl);
        if (value == .container and value.container.file == k.file and value.container.scope == k.scope) return true;
    }
    return false;
}

/// The union field a prong's capture takes by value (`.set => |s|`): the prong's one item names
/// it, and the switch's operand is a union declaring it.
fn prongField(c: *Context, capture: Facts.Decl) Context.Error!?Facts.Decl {
    const model = &c.project.at(capture.file).model;
    const tree = &c.project.at(capture.file).file.tree;
    const case_node = model.declarations[@backingInt(capture.index)].node;
    const case = tree.fullSwitchCase(case_node) orelse return null;
    const payload = case.payload_token orelse return null;
    if (tree.tokenTag(payload) == .asterisk or case.ast.values.len != 1) return null;
    const item = case.ast.values[0];
    const named_tag = (try c.facts.literalOf(capture.file, item)) orelse return null;
    if (named_tag != .enum_literal) return null;
    const switch_node = model.parentOf(case_node) orelse return null;
    const full = tree.fullSwitch(switch_node) orelse return null;
    var operand = try c.facts.resolve(capture.file, full.ast.condition);
    if (operand == .pointer) operand = operand.pointer.child.*;
    const container = switch (operand) {
        .instance, .container => |k| k,
        .alternatives => return null,
        else => return null,
    };
    const member = c.facts.member(container, named_tag.enum_literal) orelse return null;
    if (c.project.at(member.file).model.declarations[@backingInt(member.index)].kind != .field) return null;
    return member;
}

/// The declared length of the fixed array a name holds, or points to (`var buf: [256]u8`,
/// `const t = [_]u8{ ... }`, a field `table: *const [256][4]u8`), its length a constant.
fn fixedLength(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Context.Error!?Magnitude {
    var decl = ((try c.facts.definition(file, memory)).orNull()) orelse return null;
    var record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    // A prong's capture of a union's field (`.set => |s|`) has that field's type.
    if (record.kind == .capture) {
        decl = (try prongField(c, decl)) orelse return null;
        record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    }
    const decl_tree = &c.project.at(decl.file).file.tree;
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
                if (call.ast.params.len != 1 or formAt(decl_tree, call.ast.fn_expr) != .member) return null;
                const creates = try c.facts.resolve(decl.file, call.ast.fn_expr);
                if (creates != .function or try Governed.isStd(c, creates.function, "mem.Allocator.create") != .yes) return null;
                if (!try allocator(c, decl.file, decl_tree.nodeData(call.ast.fn_expr).node_and_token[0])) return null;
                break :blk call.ast.params[0];
            }
            var buffer: [2]Ast.Node.Index = undefined;
            const literal_init = decl_tree.fullArrayInit(&buffer, init) orelse return null;
            const array_type = literal_init.ast.type_expr.unwrap() orelse return null;
            const array = (try c.facts.arrayType(decl.file, array_type)) orelse return null;
            if (array.length == null) return literal_init.ast.elements.len;
            break :blk array_type;
        },
        .field => (c.project.at(decl.file).model.containerField(decl_tree, record.node) orelse return null).ast.type_expr.unwrap(),
        // A parameter holds what its type says: the compiler checks every call gives that.
        .parameter => c.facts.parameterTypeNode(decl),
        else => null,
    };
    var t = type_node orelse return null;
    // A pointer to one array (`*const [256][4]u8`) is indexed as the array is.
    if (decl_tree.fullPtrType(t)) |pointer| {
        if (pointer.size != .one) return null;
        t = pointer.ast.child_type;
    }
    const array = (try c.facts.arrayType(decl.file, t)) orelse return null;
    return (try valueOf(c, array.file, array.length orelse return null, 0)) orelse null;
}

/// The integer type an expression computes in at a pointer width, where it is one (Bounds).
pub fn intOf(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    return switch (try typeOf(c, file, node, pointer, 0)) {
        .int => |int| int,
        else => null,
    };
}

/// The integer type a type expression names at a pointer width (Bounds).
pub fn intNamed(c: *Context, file: Project.FileId, type_node: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    return named(c, file, type_node, pointer);
}

/// The integer type `type_node` names in `reading`, one reading of a call of the function it is
/// in (`comptime T: type` given `usize`), or as written where there is none (Bounds).
pub fn intNamedIn(c: *Context, reading: ?*const Facts.Env, file: Project.FileId, type_node: Ast.Node.Index, pointer: u16) Context.Error!?Int {
    const env = reading orelse return named(c, file, type_node, pointer);
    return switch (integer(try c.facts.resolveBound(env, file, type_node), pointer)) {
        .int => |int| int,
        else => null,
    };
}

/// The value of a constant expression, where the program fixes one (Bounds).
pub fn constantValue(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?u64 {
    return valueOf(c, file, node, 0);
}

/// The length an array's type fixes for memory, where it is one (Bounds).
pub fn memoryLength(c: *Context, file: Project.FileId, memory: Ast.Node.Index) Context.Error!?Magnitude {
    return fixedLength(c, file, memory);
}

/// The greatest length of memory at a pointer width (Bounds).
pub fn longest(pointer: u16) Magnitude {
    return length(pointer);
}

/// The greatest value `node` can have where it is never below zero, read as a step a loop
/// takes or a switch's subject (Bounds): null where either is not shown.
pub fn stepMost(c: *Context, file: Project.FileId, node: Ast.Node.Index, pointer: u16) Context.Error!?Magnitude {
    if (!try nonnegative(c, file, node, pointer)) return null;
    return bound(c, file, node, pointer, 0);
}

/// The pointer widths a range is read at (Bounds).
pub fn pointerWidths(c: *const Context) []const u16 {
    return widths(c);
}
