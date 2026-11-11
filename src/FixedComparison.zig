//! Hygiene: a comparison whose result is fixed by its operand's type: an unsigned value compared
//! with a written `0` by `<` (never true) or `>=` (always true), either side: `x < 0`, `0 > x`,
//! `x >= 0`, `0 <= x`. The unsigned value is a slice's or an array's `len` (a `usize`, read where
//! the holder resolves to a slice or an array, never another struct's `len` field), or a name
//! whose declaration writes an unsigned integer type. Zig compiles both forms.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const lhs, const rhs = switch (tag) {
            .less_than, .greater_than, .less_or_equal, .greater_or_equal => tree.nodeData(node).node_and_node,
            else => continue,
        };
        // The unsigned operand and whether the comparison is `value < 0` (else `value >= 0`).
        const value: Ast.Node.Index, const never: bool = if (zero(tree, rhs)) switch (tag) {
            .less_than => .{ lhs, true },
            .greater_or_equal => .{ lhs, false },
            else => continue,
        } else if (zero(tree, lhs)) switch (tag) {
            .greater_than => .{ rhs, true },
            .less_or_equal => .{ rhs, false },
            else => continue,
        } else continue;
        if (!try unsigned(c, tree, value)) continue;
        try c.at(rule, tree.nodeMainToken(node), if (never) "an unsigned value compared below 0: this is never true" else "an unsigned value compared at or above 0: this is always true");
    }
}

fn zero(tree: *const Ast, node: Ast.Node.Index) bool {
    const at = Written.ungrouped(tree, node);
    return tree.nodeTag(at) == .number_literal and Written.literalInteger(tree, at) == 0;
}

/// Whether `node` is unsigned by its form or its written type: `h.len` of a slice or an array,
/// or a name declared `uN` / `usize` / an unsigned C integer.
fn unsigned(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!bool {
    const at = Written.ungrouped(tree, node);
    if (tree.nodeTag(at) == .field_access) {
        const holder, const name = tree.nodeData(at).node_and_token;
        if (!std.mem.eql(u8, tree.tokenSlice(name), "len")) return false;
        return switch (try c.facts.resolve(c.file, holder)) {
            .array => true,
            .pointer => |p| p.size == .slice or p.child.* == .array,
            else => false,
        };
    }
    const written = Written.typeOf(tree, &c.project.at(c.file).model, at) orelse return false;
    return switch (Written.primitive(tree, written) orelse return false) {
        .sized => |sized| !sized.signed,
        .integer => |integer| !integer.signed,
        .float, .boolean => false,
    };
}

const breadth = @import("breadth_test.zig");

test "breadth: fixed comparison: an unsigned value against 0 reported both ways and either side; signed, other fields, other bounds not" {
    try breadth.expectFindings(check, "pub fn f(x: u32) bool { return x < 0; }", 1);
    try breadth.expectFindings(check, "pub fn f(x: usize) bool { return x >= 0; }", 1);
    try breadth.expectFindings(check, "pub fn f(x: u8) bool { return 0 > x or 0 <= x; }", 2);
    try breadth.expectFindings(check, "pub fn f(s: []const u8) bool { return s.len < 0; }", 1);
    try breadth.expectFindings(check, "pub fn f(a: [4]u8) bool { return a.len >= 0; }", 1);
    try breadth.expectFindings(check, "pub fn f(x: i32) bool { return x < 0; }", 0);
    try breadth.expectFindings(check, "pub fn f(x: u32) bool { return x > 0 and x <= 0; }", 0);
    try breadth.expectFindings(check, "const S = struct { len: i32 }; pub fn f(s: S) bool { return s.len < 0; }", 0);
    try breadth.expectFindings(check, "pub fn f(x: anytype) bool { return x < 0; }", 0);
}
