//! Hygiene: a loop whose body leaves it on the first pass whatever happens: a `while` or `for`
//! whose body ends, as its last statement at the body's own level, in a `break` or a `return`,
//! with no `continue` anywhere in the body that goes to this loop (`Facts.accesses.breakTarget`).
//! Its body runs once at most: a labeled block, or an `if`, says that. A body that is a single
//! `break` or `return` is one such body.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const body, const keyword = if (tree.fullWhile(node)) |loop|
            .{ loop.ast.then_expr, loop.ast.while_token }
        else if (tree.fullFor(node)) |loop|
            .{ loop.ast.then_expr, loop.ast.for_token }
        else
            continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const last = if (tree.blockStatements(&buffer, body)) |statements|
            (if (statements.len == 0) continue else statements[statements.len - 1])
        else
            body;
        switch (tree.nodeTag(last)) {
            .@"break", .@"return" => {},
            else => continue,
        }
        if (continues(tree, model, node, body)) continue;
        try c.at(rule, keyword, "this loop leaves on its first pass: its body ends in an unconditional break or return and nothing continues it");
    }
}

/// Whether a `continue` in `body` goes to `loop`.
fn continues(tree: *const Ast, model: *const @import("Model.zig"), loop: Ast.Node.Index, body: Ast.Node.Index) bool {
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"continue") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(jump);
        if (token < first or token > last) continue;
        // One whose target is not found may go to this loop.
        const target = Facts.accesses.breakTarget(tree, model, jump) orelse return true;
        if (target == loop) return true;
    }
    return false;
}

const breadth = @import("breadth.zig");

test "breadth: never loops: a body ending in break or return reported; a continue to it, an inner loop's, a conditional exit not" {
    try breadth.expectFindings(check, "pub fn f(s: []const u8) u8 { for (s) |b| { return b; } return 0; }", 1);
    try breadth.expectFindings(check, "pub fn f(n: u32) u32 { var i: u32 = 0; while (i < n) { i += 1; break; } return i; }", 1);
    try breadth.expectFindings(check, "pub fn f(n: u32) u32 { var i: u32 = 0; while (i < n) : (i += 1) { if (i == 3) continue; break; } return i; }", 0);
    try breadth.expectFindings(check, "pub fn f(s: []const u8) u8 { for (s) |b| { if (b == 0) return b; } return 0; }", 0);
    try breadth.expectFindings(check, "pub fn f(s: []const u8) u8 { outer: for (s) |b| { for (s) |c| { if (c == b) continue :outer; } return b; } return 0; }", 0);
    try breadth.expectFindings(check, "pub fn f(s: []const u8) u8 { for (s) |b| { for (s) |c| { if (c == b) continue; } return b; } return 0; }", 1);
}
