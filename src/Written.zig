//! What the breadth hygiene rules read of the syntax: the type a name's declaration writes, the
//! primitive a type's spelling names, and whether two expressions are written alike. Nothing here
//! follows a value: a name with no written type, or a spelling that names no primitive, is null,
//! and a rule reading it reports nothing there.
const std = @import("std");
const Ast = std.zig.Ast;
const Model = @import("Model.zig");

/// The type expression the declaration a bare name refers to writes: a parameter's type, or a
/// variable's `: T`. Null for any other expression, a name that does not resolve, a declaration
/// of another kind, or one whose type is not written.
pub fn typeOf(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    const named = ungrouped(tree, node);
    if (tree.nodeTag(named) != .identifier) return null;
    const reference = model.reference(named) orelse return null;
    const d = reference.declaration orelse return null;
    const record = model.declarations[@backingInt(d)];
    var buffer: [1]Ast.Node.Index = undefined;
    return switch (record.kind) {
        // A parameter with no type expression (`anytype`) records its prototype instead.
        .parameter => if (tree.fullFnProto(&buffer, record.node) == null) record.node else null,
        .variable => (tree.fullVarDecl(record.node) orelse return null).ast.type_node.unwrap(),
        .function, .capture, .field => null,
    };
}

/// A primitive type by its spelling. Zig refuses a declaration that shadows a primitive's name,
/// so the spelling is the type. `sized` is an integer of a width the spelling states (`u32`,
/// `i7`); `integer` one whose width depends on the target or the C ABI (`usize`, `c_int`) or is
/// none (`comptime_int`).
pub const Primitive = union(enum) {
    sized: struct { signed: bool, bits: u16 },
    integer: struct { signed: bool },
    float,
    boolean,
};

/// The primitive the type expression `node` names by its spelling, parentheses aside; null for
/// any other type.
pub fn primitive(tree: *const Ast, node: Ast.Node.Index) ?Primitive {
    const named = ungrouped(tree, node);
    if (tree.nodeTag(named) != .identifier) return null;
    const name = tree.tokenSlice(tree.nodeMainToken(named));
    if (name.len >= 2 and (name[0] == 'u' or name[0] == 'i')) sized: {
        for (name[1..]) |c| if (!std.ascii.isDigit(c)) break :sized;
        if (name.len > 2 and name[1] == '0') break :sized;
        // Zig's widest integer is 65535 bits: five digits at most.
        if (name.len > 6) break :sized;
        var bits: u32 = 0;
        for (name[1..]) |c| bits = bits * 10 + (c - '0');
        if (bits > std.math.maxInt(u16)) break :sized;
        return .{ .sized = .{ .signed = name[0] == 'i', .bits = @intCast(bits) } };
    }
    const unsigned = [_][]const u8{ "usize", "c_uint", "c_ulong", "c_ulonglong", "c_ushort", "c_uchar" };
    const signed = [_][]const u8{ "isize", "c_int", "c_long", "c_longlong", "c_short", "c_char", "comptime_int" };
    const floats = [_][]const u8{ "f16", "f32", "f64", "f80", "f128", "c_longdouble", "comptime_float" };
    for (unsigned) |each| if (std.mem.eql(u8, name, each)) return .{ .integer = .{ .signed = false } };
    for (signed) |each| if (std.mem.eql(u8, name, each)) return .{ .integer = .{ .signed = true } };
    for (floats) |each| if (std.mem.eql(u8, name, each)) return .float;
    if (std.mem.eql(u8, name, "bool")) return .boolean;
    return null;
}

/// Whether two expressions are written with the same tokens, each the same kind and spelling.
pub fn sameTokens(tree: *const Ast, a: Ast.Node.Index, b: Ast.Node.Index) bool {
    const a_first = tree.firstToken(a);
    const a_last = tree.lastToken(a);
    const b_first = tree.firstToken(b);
    const b_last = tree.lastToken(b);
    if (a_last - a_first != b_last - b_first) return false;
    for (0..a_last - a_first + 1) |i| {
        const x: Ast.TokenIndex = @intCast(a_first + i);
        const y: Ast.TokenIndex = @intCast(b_first + i);
        if (tree.tokenTag(x) != tree.tokenTag(y)) return false;
        if (!std.mem.eql(u8, tree.tokenSlice(x), tree.tokenSlice(y))) return false;
    }
    return true;
}

/// Whether an expression may run code when it is evaluated: a parenthesis that opens a call
/// (after a name, a builtin, a closing parenthesis or bracket, or a keyword such as `fn`), or a
/// dereference, which may read volatile memory. A grouping parenthesis after an operator is none.
/// Two such expressions written alike may still differ, so a rule reads neither.
pub fn mayRun(tree: *const Ast, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var token = first;
    while (token <= last) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .period_asterisk => return true,
            .l_paren => if (token > first) switch (tree.tokenTag(token - 1)) {
                .identifier, .builtin, .r_paren, .r_bracket, .r_brace, .keyword_fn => return true,
                else => {},
            },
            else => {},
        }
    }
    return false;
}

/// `node` with its parentheses taken off.
pub fn ungrouped(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
    return at;
}

/// The value of an integer literal, or of `*`, `+`, `<<` over such literals; null for any other.
pub fn literalInteger(tree: *const Ast, node: Ast.Node.Index) ?u128 {
    const at = ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .number_literal => {
            return switch (std.zig.parseNumberLiteral(tree.tokenSlice(tree.nodeMainToken(at)))) {
                .int => |value| value,
                .big_int, .float, .failure => null,
            };
        },
        .mul, .add, .shl => {
            const lhs, const rhs = tree.nodeData(at).node_and_node;
            const a = literalInteger(tree, lhs) orelse return null;
            const b = literalInteger(tree, rhs) orelse return null;
            return switch (tree.nodeTag(at)) {
                .mul => std.math.mul(u128, a, b) catch null,
                .add => std.math.add(u128, a, b) catch null,
                .shl => if (b < 128) std.math.shlExact(u128, a, @intCast(b)) catch null else null,
                else => unreachable,
            };
        },
        else => return null,
    }
}
