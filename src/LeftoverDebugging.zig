//! Ban, opt-in: debugging left in the code: every `@breakpoint()`, and a `@panic` whose argument
//! is a string literal starting, in any case, with one of `todo`, `fixme`, `unimplemented` or
//! `not implemented` (a closed list: work not done, not a state the program can reach). Test code
//! included: a stub left there is left too.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");

const unfinished = [_][]const u8{ "todo", "fixme", "unimplemented", "not implemented" };

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const name = Facts.builtinName(tree, node) orelse continue;
        const token = tree.nodeMainToken(node);
        if (std.mem.eql(u8, name, "@breakpoint")) {
            try c.at(rule, token, "@breakpoint() left in the code");
            continue;
        }
        if (!std.mem.eql(u8, name, "@panic")) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, node, &buffer);
        if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) continue;
        const literal = tree.tokenSlice(tree.nodeMainToken(args[0]));
        if (literal.len < 2) continue;
        const text = std.mem.trimStart(u8, literal[1 .. literal.len - 1], " ");
        for (unfinished) |word| if (text.len >= word.len and std.ascii.eqlIgnoreCase(text[0..word.len], word)) {
            try c.at(rule, token, "a panic that marks work not done: finish it, or return an error");
            break;
        };
    }
}

const breadth = @import("breadth.zig");

test "breadth: leftover debugging: a breakpoint and an unfinished panic reported; a real panic message not" {
    try breadth.expectFindings(check, "pub fn f() void { @breakpoint(); }", 1);
    try breadth.expectFindings(check, "pub fn f() void { @panic(\"TODO: decode\"); }", 1);
    try breadth.expectFindings(check, "pub fn f() void { @panic(\"not implemented yet\"); }", 1);
    try breadth.expectFindings(check, "pub fn f() void { @panic(\"index out of range\"); }", 0);
}
