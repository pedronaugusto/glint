//! Hygiene: a loop counter narrower than the bound it counts to: `while (i < n) : (i += 1)` where
//! `i`'s declaration writes `uN`/`iN` narrower than `n`'s. Where `n` passes what `i` can hold, `i`
//! overflows before the loop ends: a safe build panics, a fast one loops on. Read: a `while` whose
//! condition is `i < n`, `i <= n`, `n > i` or `n >= i` with both names' types written, and whose
//! continue expression is `i += …` on the same name. A bound of `usize` or `isize` is at least 16
//! bits on every target Zig builds for, so a counter of fewer than 16 bits is narrower than it.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const loop = tree.fullWhile(node) orelse continue;
        const step = loop.ast.cont_expr.unwrap() orelse continue;
        if (tree.nodeTag(step) != .assign_add) continue;
        const stepped = tree.nodeData(step).node_and_node[0];
        const condition = Written.ungrouped(tree, loop.ast.cond_expr);
        const lhs, const rhs = switch (tree.nodeTag(condition)) {
            .less_than, .less_or_equal, .greater_than, .greater_or_equal => tree.nodeData(condition).node_and_node,
            else => continue,
        };
        const counter, const bound = switch (tree.nodeTag(condition)) {
            .less_than, .less_or_equal => .{ lhs, rhs },
            else => .{ rhs, lhs },
        };
        if (!Written.sameTokens(tree, counter, stepped)) continue;
        const counter_bits = switch (Written.primitive(tree, Written.typeOf(tree, model, counter) orelse continue) orelse continue) {
            .sized => |sized| sized.bits,
            else => continue,
        };
        const narrower = switch (Written.primitive(tree, Written.typeOf(tree, model, bound) orelse continue) orelse continue) {
            .sized => |sized| counter_bits < sized.bits,
            .integer => counter_bits < 16,
            .float, .boolean => false,
        };
        if (!narrower) continue;
        try c.at(rule, loop.ast.while_token, try c.allocator.print("the counter is {d} bits and its bound wider: where the bound passes what the counter holds, it overflows before the loop ends", .{counter_bits}));
    }
}

const breadth = @import("breadth_test.zig");

test "breadth: narrow counter: a u8 counter to a u16 or usize bound reported; as wide, or another step, not" {
    try breadth.expectFindings(check, "pub fn f(n: u16) void { var i: u8 = 0; while (i < n) : (i += 1) {} }", 1);
    try breadth.expectFindings(check, "pub fn f(n: usize) void { var i: u8 = 0; while (n > i) : (i += 1) {} }", 1);
    try breadth.expectFindings(check, "pub fn f(n: u16) void { var i: u16 = 0; while (i < n) : (i += 1) {} }", 0);
    try breadth.expectFindings(check, "pub fn f(n: usize) void { var i: u32 = 0; while (i < n) : (i += 1) {} }", 0);
    try breadth.expectFindings(check, "pub fn f(n: u16) void { var i: u8 = 0; var j: u8 = 0; while (i < n) : (j += 1) { i += 1; } }", 0);
}
