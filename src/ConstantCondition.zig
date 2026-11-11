//! Hygiene: a condition written as a literal, so its branch is decided as written: `if (true)`,
//! `if (false)`, `while (false)`, through parentheses. `while (true)` is the language's loop
//! without a condition, not read. An `if` on a comptime-known name (`builtin.mode`) is not a
//! literal and not read.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const condition, const keyword, const loop = if (tree.fullIf(node)) |branch|
            .{ branch.ast.cond_expr, branch.ast.if_token, false }
        else if (tree.fullWhile(node)) |each|
            .{ each.ast.cond_expr, each.ast.while_token, true }
        else
            continue;
        const at = Written.ungrouped(tree, condition);
        if (tree.nodeTag(at) != .identifier) continue;
        const spelled = tree.tokenSlice(tree.nodeMainToken(at));
        const value = if (std.mem.eql(u8, spelled, "true")) true else if (std.mem.eql(u8, spelled, "false")) false else continue;
        if (loop and value) continue;
        try c.at(rule, keyword, if (value) "a condition written `true`: the branch always runs" else if (loop) "a loop on `false`: its body never runs" else "a condition written `false`: the branch never runs");
    }
}

const breadth = @import("breadth.zig");

test "breadth: constant condition: if (true), if (false), while (false) reported; while (true) and a name not" {
    try breadth.expectFindings(check, "pub fn f() u8 { if (true) return 1; if ((false)) return 2; while (false) {} return 0; }", 3);
    try breadth.expectFindings(check, "pub fn f(n: u8) u8 { var i: u8 = 0; while (true) { i += 1; if (i == n) break; } return i; }", 0);
    try breadth.expectFindings(check, "const debug = true; pub fn f() u8 { if (debug) return 1; return 0; }", 0);
}
