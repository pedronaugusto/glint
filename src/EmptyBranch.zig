//! Hygiene, opt-in: an `if` or `else` body written `{}` with nothing between its braces, not even
//! a comment: what it protects against is a branch whose body was forgotten. A comment inside is
//! the author's stated reason (as Z026 reads a written one). Loops are not read (a spin or a drain
//! loop is legitimate), nor `switch` prongs (an empty prong is how Zig says "nothing here").
//! Comments are not tokens, so the bytes between the braces are read.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const branch = tree.fullIf(node) orelse continue;
        try body(c, rule, tree, branch.ast.then_expr, "an empty if body with no comment: write what it is for, or remove the branch");
        if (branch.ast.else_expr.unwrap()) |otherwise| try body(c, rule, tree, otherwise, "an empty else body with no comment: write what it is for, or remove it");
    }
}

fn body(c: *Context, rule: Rule, tree: *const Ast, node: Ast.Node.Index, message: []const u8) Context.Error!void {
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node) orelse return;
    if (statements.len != 0) return;
    const open = tree.firstToken(node);
    const close = tree.lastToken(node);
    const between = tree.source[tree.tokenToSpan(open).end..tree.tokenStart(close)];
    if (std.mem.find(u8, between, "//") != null) return;
    try c.at(rule, open, message);
}

const breadth = @import("breadth.zig");

test "breadth: empty branch: an empty if or else body reported; one with a comment, a loop, a prong not" {
    try breadth.expectFindings(check, "pub fn f(a: bool) void { if (a) {} }", 1);
    try breadth.expectFindings(check, "fn g() void {} pub fn f(a: bool) void { if (a) g() else {} }", 1);
    try breadth.expectFindings(check, "pub fn f(a: bool) void { if (a) {\n    // nothing to do when a holds\n} }", 0);
    try breadth.expectFindings(check, "pub fn f(a: *bool) void { while (a.*) {} }", 0);
    try breadth.expectFindings(check, "pub fn f(a: u8) void { switch (a) { 0 => {}, else => {} } }", 0);
}
