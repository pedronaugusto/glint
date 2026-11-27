//! Ban, opt-in: debugging left in the code: every `@breakpoint()`, and a `@panic` whose argument
//! is a string literal (or literals joined by `++`) starting, in any case, with one of `todo`, `fixme`, `unimplemented` or
//! `not implemented` (a closed list: work not done, not a state the program can reach), and std's
//! formatted `std.debug.panic` whose format so starts. Test code included: a stub left there is
//! left too.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Facts = @import("Facts.zig");
const Governed = @import("Governed.zig");

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
        if (args.len != 1 or !marksUnfinished(tree, args[0])) continue;
        try c.at(rule, token, "a panic that marks work not done: finish it, or return an error");
    }
    // std's formatted panic, `std.debug.panic(format, args)`: the same panic, its message the
    // format. Read by its form first, then by its callee: a call glint cannot name is no pass
    // only where it is written so (`Context.unknownAt`).
    for (try c.callsIn(c.file)) |call| {
        var buffer: [1]Ast.Node.Index = undefined;
        const written = tree.fullCall(&buffer, call.node) orelse continue;
        if (written.ast.params.len != 2 or !marksUnfinished(tree, written.ast.params[0])) continue;
        const token = tree.nodeMainToken(call.node);
        switch (try Governed.mayCallStd(c, call.node, "debug.panic")) {
            .no => {},
            .yes => try c.at(rule, token, "a panic that marks work not done: finish it, or return an error"),
            .unknown => |why| try c.unknownAt(rule, token, why),
        }
    }
}

/// Whether `node` is a string literal starting, in any case and past spaces, with one of the
/// `unfinished` markers: a literal written whole, or literals joined by `++` (through parentheses),
/// read as the one text the compiler makes of them.
fn marksUnfinished(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [32]u8 = undefined;
    var written: usize = 0;
    // A part that is no literal leaves what follows it unknown: the text read so far is all.
    _ = appendLiteral(tree, node, &buffer, &written);
    const text = std.mem.trimStart(u8, buffer[0..written], " ");
    for (unfinished) |word| if (text.len >= word.len and std.ascii.eqlIgnoreCase(text[0..word.len], word)) return true;
    return false;
}

/// Appends what the string literals of `node` spell, left to right, to `buffer` up to its length;
/// false at the first part that is no string literal, a `++` of them, or parentheses around one.
fn appendLiteral(tree: *const Ast, node: Ast.Node.Index, buffer: *[32]u8, written: *usize) bool {
    switch (tree.nodeTag(node)) {
        .grouped_expression => return appendLiteral(tree, tree.nodeData(node).node_and_token[0], buffer, written),
        .array_cat => {
            const left, const right = tree.nodeData(node).node_and_node;
            return appendLiteral(tree, left, buffer, written) and appendLiteral(tree, right, buffer, written);
        },
        .string_literal => {
            const literal = tree.tokenSlice(tree.nodeMainToken(node));
            if (literal.len < 2) return false;
            const inner = literal[1 .. literal.len - 1];
            const room = @min(inner.len, buffer.len - written.*);
            @memcpy(buffer[written.*..][0..room], inner[0..room]);
            written.* += room;
            return true;
        },
        else => return false,
    }
}

const breadth = @import("breadth_test.zig");

test "breadth: leftover debugging: a breakpoint and an unfinished panic reported; a real panic message not" {
    try breadth.expectFindings(check, "pub fn f() void { @breakpoint(); }", 1);
    try breadth.expectFindings(check, "pub fn f() void { @panic(\"TODO: decode\"); }", 1);
    try breadth.expectFindings(check, "pub fn f() void { @panic(\"not implemented yet\"); }", 1);
    try breadth.expectFindings(check, "pub fn f() void { @panic(\"index out of range\"); }", 0);
    // Literals joined by `++` are the one message the compiler makes of them.
    try breadth.expectFindings(check, "pub fn f() void { @panic(\"TO\" ++ \"DO: decode\"); }", 1);
    try breadth.expectFindings(check, "pub fn f() void { @panic((\"not \" ++ \"implemented\")); }", 1);
    try breadth.expectFindings(check, "const m = \"x\"; pub fn f() void { @panic(\"index \" ++ m); }", 0);
    // std's formatted panic, its message the format: as written and through an alias.
    try breadth.expectFindings(check, "const std = @import(\"std\"); const panic = std.debug.panic; pub fn f(n: u8) void { std.debug.panic(\"TODO: {d}\", .{n}); panic(\"fixme\", .{}); }", 2);
    try breadth.expectFindings(check, "const std = @import(\"std\"); pub fn f(n: u8) void { std.debug.panic(\"index {d} out of range\", .{n}); }", 0);
}
