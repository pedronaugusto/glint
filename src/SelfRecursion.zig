//! Hygiene: a function that calls itself before anything can stop it, so every call recurses
//! until the stack is gone. Read: the statements at the top of a function body, in order, up to
//! the first one that calls itself by its own name; each before it may hold no call, no branch,
//! no loop and no exit (a `try`, `catch`, `orelse`, `if`, `switch`, `while`, `for`, `return`,
//! `break`, `continue`, `unreachable` or a block), so nothing before can leave or diverge. The
//! call itself is a statement, a `return`, a `try`, a discard, or a declaration's value.
//! Zig compiles such a function; the program aborts on the overflow.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .function) continue;
        const parent = model.parentOf(decl.node) orelse continue;
        if (tree.nodeTag(parent) != .fn_decl) continue;
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, tree.nodeData(parent).node_and_node[1]) orelse continue;
        for (statements) |statement| {
            if (callsSelf(tree, model, statement, @fromBackingInt(@intCast(d)))) {
                try c.at(rule, tree.firstToken(statement), try c.allocator.print("'{s}' calls itself before anything can return or branch: every call recurses until the stack overflows", .{decl.name}));
                break;
            }
            if (Written.mayRun(tree, statement) or stops(tree, statement)) break;
        }
    }
}

/// Whether `statement` is a direct call of the function `self` by its name: alone, returned,
/// tried, discarded, or a declaration's value.
fn callsSelf(tree: *const Ast, model: *const @import("Model.zig"), statement: Ast.Node.Index, self: @import("Model.zig").Declaration.Id) bool {
    var at = Written.ungrouped(tree, statement);
    switch (tree.nodeTag(at)) {
        .@"return" => at = tree.nodeData(at).opt_node.unwrap() orelse return false,
        .assign => {
            const target, const value = tree.nodeData(at).node_and_node;
            if (tree.nodeTag(target) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(target)), "_")) return false;
            at = value;
        },
        else => if (tree.fullVarDecl(at)) |declared| {
            at = declared.ast.init_node.unwrap() orelse return false;
        },
    }
    at = Written.ungrouped(tree, at);
    if (tree.nodeTag(at) == .@"try") at = Written.ungrouped(tree, tree.nodeData(at).node);
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, at) orelse return false;
    const callee = call.ast.fn_expr;
    if (tree.nodeTag(callee) != .identifier) return false;
    const reference = model.reference(callee) orelse return false;
    return reference.declaration == self;
}

/// Whether a statement may leave, branch or diverge, by the keywords and forms it holds.
fn stops(tree: *const Ast, statement: Ast.Node.Index) bool {
    var token = tree.firstToken(statement);
    while (token <= tree.lastToken(statement)) : (token += 1) {
        switch (tree.tokenTag(token)) {
            .keyword_try, .keyword_catch, .keyword_orelse, .keyword_if, .keyword_switch, .keyword_while, .keyword_for, .keyword_return, .keyword_break, .keyword_continue, .keyword_unreachable, .l_brace => return true,
            else => {},
        }
    }
    return false;
}

const breadth = @import("breadth_test.zig");

test "breadth: self recursion: a call of itself first reported; one after a branch, a call or a try not" {
    try breadth.expectFindings(check, "pub fn f(n: u32) u32 { return f(n + 1); }", 1);
    try breadth.expectFindings(check, "pub fn f(n: u32) void { const m = n * 2; f(m); }", 1);
    try breadth.expectFindings(check, "pub fn f(n: u32) !void { _ = n; try f(1); }", 1);
    try breadth.expectFindings(check, "pub fn f(n: u32) u32 { if (n == 0) return 0; return f(n - 1); }", 0);
    try breadth.expectFindings(check, "fn g() void {} pub fn f(n: u32) void { g(); f(n); }", 0);
    try breadth.expectFindings(check, "fn g() !void {} pub fn f(n: u32) !void { try g(); try f(n); }", 0);
    try breadth.expectFindings(check, "fn other(n: u32) u32 { return n; } pub fn f(n: u32) u32 { return other(n); }", 0);
}
