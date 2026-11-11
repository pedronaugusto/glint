//! Ban, opt-in: `undefined` outside a `test` block. A value given `undefined` holds whatever the
//! memory held; reading it before a write is undefined behaviour no build checks. Each site needs
//! the reason it is written before it is read, at the site, or a seam. This is the ban form of the
//! undefined-read flow 0.8 parked.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const token = tree.nodeMainToken(node);
        if (!std.mem.eql(u8, tree.tokenSlice(token), "undefined") or c.inTest(token)) continue;
        try c.at(rule, token, "`undefined`: a read before a write is undefined behaviour no build checks; write the reason it is written first at this site");
    }
}

const breadth = @import("breadth_test.zig");

test "breadth: undefined reason: each undefined outside tests reported" {
    try breadth.expectFindings(check, "pub fn f() u8 { var b: [4]u8 = undefined; b[0] = 1; return b[0]; }", 1);
    try breadth.expectFindings(check, "pub fn f() u8 { return 0; }", 0);
    try breadth.expectFindings(check, "test { var b: [4]u8 = undefined; _ = &b; }", 0);
}
