//! Hygiene: an operation whose two operands are written alike, so its result is fixed by the
//! operator, or a store that changes nothing.
//! - `a OP a` for OP in `and` `or` `-` `^` `|` `&`, the two sides written with the same tokens.
//! - `a OP a` for a comparison (`==` `!=` `<` `<=` `>` `>=`) where `a` is a name whose declaration
//!   writes an integer or `bool` type: a float's `x != x` is its NaN test, and an operand whose
//!   type is not written is not read.
//! - `x = x`, a place assigned itself.
//! - `a = b; b = a;` as consecutive statements: the swap written without a temporary, which
//!   leaves both holding `b`.
//! An operand that may run code (a call, a dereference: `Written.mayRun`) is not read: two
//! evaluations of it may differ. Only what is certain is reported; a miss reports nothing.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        switch (tag) {
            .bool_and, .bool_or, .sub, .bit_xor, .bit_or, .bit_and, .equal_equal, .bang_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                if (Written.mayRun(tree, lhs) or !Written.sameTokens(tree, lhs, rhs)) continue;
                switch (tag) {
                    .equal_equal, .bang_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal, .sub => {
                        // Not a float, by the type its declaration writes: `x != x` tests a float
                        // for NaN, and `x - x` of an infinity is NaN.
                        const written = Written.typeOf(tree, model, lhs) orelse continue;
                        switch (Written.primitive(tree, written) orelse continue) {
                            .sized, .integer, .boolean => {},
                            .float => continue,
                        }
                    },
                    else => {},
                }
                try c.at(rule, tree.nodeMainToken(node), try c.allocator.print("both operands of `{s}` are written alike: its result does not depend on them", .{tree.tokenSlice(tree.nodeMainToken(node))}));
            },
            .assign => {
                const target, const value = tree.nodeData(node).node_and_node;
                if (tree.nodeTag(target) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) continue;
                if (Written.mayRun(tree, target) or !Written.sameTokens(tree, target, value)) continue;
                try c.at(rule, tree.nodeMainToken(node), "a place assigned itself: the store changes nothing");
            },
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var buffer: [2]Ast.Node.Index = undefined;
                const statements = tree.blockStatements(&buffer, node) orelse continue;
                if (statements.len < 2) continue;
                for (statements[0 .. statements.len - 1], statements[1..]) |first, second| {
                    if (tree.nodeTag(first) != .assign or tree.nodeTag(second) != .assign) continue;
                    const a, const b = tree.nodeData(first).node_and_node;
                    const b2, const a2 = tree.nodeData(second).node_and_node;
                    if (Written.mayRun(tree, a) or Written.mayRun(tree, b)) continue;
                    if (Written.sameTokens(tree, a, b)) continue; // `x = x` is reported above.
                    if (!Written.sameTokens(tree, a, a2) or !Written.sameTokens(tree, b, b2)) continue;
                    try c.at(rule, tree.nodeMainToken(second), "the second half of a swap written without a temporary: both places now hold the same value");
                }
            },
            else => {},
        }
    }
}

const breadth = @import("breadth_test.zig");

test "breadth: same operands: each form reported, a float compared with itself and an operand that runs code not" {
    try breadth.expectFindings(check, "pub fn f(a: u32, b: bool) bool { return a == a or (b and b); }", 2);
    try breadth.expectFindings(check, "pub fn f(a: u32) u32 { return (a ^ a) | (a & a); }", 2);
    try breadth.expectFindings(check, "pub fn f(a: u32) u32 { return a - a; }", 1);
    try breadth.expectFindings(check, "pub fn f(x: f64) bool { return x != x; }", 0);
    try breadth.expectFindings(check, "pub fn f(x: f64) f64 { return x - x; }", 0);
    try breadth.expectFindings(check, "fn g() u32 { return 1; } pub fn f() bool { return g() == g(); }", 0);
    try breadth.expectFindings(check, "pub fn f(p: *u32) bool { return p.* == p.*; }", 0);
    // A comparison whose operand's type is not written is not read.
    try breadth.expectFindings(check, "pub fn f(a: anytype) bool { return a == a; }", 0);
    try breadth.expectFindings(check, "pub fn f(a: u32, b: u32) bool { return a == b; }", 0);
}

test "breadth: same operands: a self-assignment and a swap written without a temporary" {
    try breadth.expectFindings(check, "pub fn f() void { var x: u32 = 1; x = x; _ = &x; }", 1);
    try breadth.expectFindings(check, "pub fn f() void { var a: u32 = 1; var b: u32 = 2; a = b; b = a; _ = &a; _ = &b; }", 1);
    try breadth.expectFindings(check, "pub fn f() void { var a: u32 = 1; var b: u32 = 2; const t = a; a = b; b = t; _ = &a; _ = &b; }", 0);
    try breadth.expectFindings(check, "pub fn f(s: *[2]u32) void { s[0] = s[1]; s[1] = s[0]; }", 1);
}
