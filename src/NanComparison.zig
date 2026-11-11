//! Hygiene: a comparison with NaN, which is false for every operator but `!=`, where it is true:
//! `x == std.math.nan(f64)` is never true. Use `std.math.isNan(x)`. Read: an operand that is a
//! call whose every callee is std's `math.nan` (`Governed.stdCall`, through aliases), in `==`,
//! `!=`, `<`, `<=`, `>`, `>=`.
const Ast = @import("std").zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .equal_equal, .bang_equal, .less_than, .less_or_equal, .greater_than, .greater_or_equal => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const lhs, const rhs = tree.nodeData(node).node_and_node;
        if (!try isNan(c, tree, lhs) and !try isNan(c, tree, rhs)) continue;
        try c.at(rule, tree.nodeMainToken(node), if (tag == .bang_equal) "a comparison with NaN: `!=` is always true; use std.math.isNan" else "a comparison with NaN: it is always false; use std.math.isNan");
    }
}

fn isNan(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!bool {
    const at = Written.ungrouped(tree, node);
    if (!Facts.calls.written(tree, at)) return false;
    return try Governed.stdCall(c, at, "math.nan") == .yes;
}

const breadth = @import("breadth_test.zig");

test "breadth: nan comparison: a comparison with std.math.nan reported; isNan and another call not" {
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(x: f64) bool { return x == std.math.nan(f64) or std.math.nan(f64) != x; }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(x: f64) bool { return std.math.isNan(x); }", 0);
    try breadth.expectFindings(check, "fn nan(comptime T: type) T { return 0; } pub fn f(x: f64) bool { return x == nan(f64); }", 0);
}
