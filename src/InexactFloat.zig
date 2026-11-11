//! Hygiene: a float compared with `==` or `!=` to a decimal literal its type cannot hold exactly
//! (`x == 0.1` where `x` is `f64`): the literal is rounded to the nearest float, and the computed
//! value is rarely that one; compare within a tolerance. The other operand is a name whose
//! declaration writes `f16`, `f32`, `f64`, `f80` or `f128`; the literal is exact where its value
//! is an odd integer of at most the type's significand bits times a power of two (`0.5`, `0`,
//! `1e3` are exact; `0.1`, `1e-3` are not). A hexadecimal float literal is always exact.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .equal_equal and tag != .bang_equal) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        const literal, const named = if (decimal(tree, rhs)) .{ rhs, lhs } else if (decimal(tree, lhs)) .{ lhs, rhs } else continue;
        const written = Written.typeOf(tree, model, named) orelse continue;
        if ((Written.primitive(tree, written) orelse continue) != .float) continue;
        const bits = significand(tree.tokenSlice(tree.nodeMainToken(Written.ungrouped(tree, written)))) orelse continue;
        const text = tree.tokenSlice(tree.nodeMainToken(Written.ungrouped(tree, literal)));
        if (exact(text, bits) orelse continue) continue;
        try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("{s} has no exact value in this float type: the comparison is against its rounding; compare within a tolerance", .{text}));
    }
}

/// Whether `node` is a decimal float literal (`0.1`, `1e-3`), through parentheses.
fn decimal(tree: *const Ast, node: Ast.Node.Index) bool {
    const at = Written.ungrouped(tree, node);
    if (tree.nodeTag(at) != .number_literal) return false;
    const text = tree.tokenSlice(tree.nodeMainToken(at));
    if (std.mem.startsWith(u8, text, "0x")) return false;
    return std.mem.findAny(u8, text, ".eE") != null;
}

/// The significand bits of a float type by its name, the implicit bit counted.
fn significand(name: []const u8) ?u8 {
    for ([_]struct { []const u8, u8 }{ .{ "f16", 11 }, .{ "f32", 24 }, .{ "f64", 53 }, .{ "f80", 64 }, .{ "f128", 113 } }) |known| {
        if (std.mem.eql(u8, name, known[0])) return known[1];
    }
    return null;
}

/// Whether the decimal literal `text` is exact in a float of `bits` significand bits; null where
/// it is not read (too many digits to decide here). Its value is M * 10^E = M * 5^E * 2^E: exact
/// where, for E < 0, 5^-E divides M and the quotient's odd part fits; for E >= 0, M * 5^E's odd
/// part fits. The exponent's range is not read: a literal that overflows is refused as it compiles.
fn exact(text: []const u8, bits: u8) ?bool {
    var mantissa: u128 = 0;
    var exponent: i32 = 0;
    var seen_point = false;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const ch = text[index];
        switch (ch) {
            '0'...'9' => {
                mantissa = std.math.mul(u128, mantissa, 10) catch return null;
                mantissa += ch - '0';
                if (seen_point) exponent -= 1;
            },
            '_' => {},
            '.' => seen_point = true,
            'e', 'E' => {
                const written = std.fmt.parseInt(i32, text[index + 1 ..], 10) catch return null;
                exponent += written;
                break;
            },
            else => return null,
        }
    }
    if (mantissa == 0) return true;
    var value = mantissa;
    if (exponent < 0) {
        var k: i32 = exponent;
        while (k < 0) : (k += 1) {
            if (value % 5 != 0) return false;
            value /= 5;
        }
    } else {
        var k: i32 = 0;
        while (k < exponent) : (k += 1) value = std.math.mul(u128, value, 5) catch return false;
    }
    while (value % 2 == 0) value /= 2;
    return 128 - @clz(value) <= bits;
}

const breadth = @import("breadth_test.zig");

test "breadth: inexact float: 0.1 and 1e-3 against a float reported; 0.5, 0, 1e3, an integer type not" {
    try breadth.expectFindings(check, "pub fn f(x: f64) bool { return x == 0.1 or 1e-3 != x; }", 2);
    try breadth.expectFindings(check, "pub fn f(x: f64) bool { return x == 0.5 or x == 0.0 or x != 1e3 or x == 0.25; }", 0);
    try breadth.expectFindings(check, "pub fn f(x: f32) bool { return x == 16777217.0; }", 1);
    try breadth.expectFindings(check, "pub fn f(x: f64) bool { return x == 16777217.0; }", 0);
    try breadth.expectFindings(check, "pub fn f(x: anytype) bool { return x == 0.1; }", 0);
    try breadth.expectFindings(check, "pub fn f(x: f64) bool { return x < 0.1; }", 0);
}
