//! Hygiene: an `if` that decides nothing it was written to decide.
//! - In one `if` / `else if` chain, a condition written with the same tokens as an earlier one:
//!   the later branch never runs where the earlier one is taken, so it runs only when the same
//!   condition is false.
//! - An `if` with an `else` whose two bodies are written with the same tokens: both paths do the
//!   same. An `else if` is a chain, not a body. An `if` that captures a payload or an error is
//!   left out, since one name may then hold a different value in each body.
//! A condition that may run code (a call, a dereference: `Written.mayRun`) is not read: it may
//! differ between evaluations. A `switch` with repeated items is already a compile error.
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
        const branch = tree.fullIf(node) orelse continue;
        // The head of a chain only: an `if` that is another's `else` is read with it.
        if (model.parentOf(node)) |parent| if (tree.fullIf(parent)) |outer| if (outer.ast.else_expr.unwrap() == node) {
            // ... and its identical-bodies form, where it is an `if` of its own.
            try identicalBodies(c, rule, tree, branch);
            continue;
        };
        try identicalBodies(c, rule, tree, branch);
        var seen: std.ArrayList(Ast.Node.Index) = .empty;
        var at = branch;
        while (true) {
            const condition = at.ast.cond_expr;
            if (!Written.mayRun(tree, condition)) {
                for (seen.items) |earlier| if (Written.sameTokens(tree, earlier, condition)) {
                    try c.at(rule, tree.firstToken(condition), "this condition repeats an earlier one in the same if/else chain: its branch runs only where that one is false, which this one then is too");
                    break;
                };
                try seen.append(c.allocator, condition);
            }
            const next = at.ast.else_expr.unwrap() orelse break;
            at = tree.fullIf(next) orelse break;
        }
    }
}

fn identicalBodies(c: *Context, rule: Rule, tree: *const Ast, branch: Ast.full.If) Context.Error!void {
    if (branch.payload_token != null or branch.error_token != null) return;
    const otherwise = branch.ast.else_expr.unwrap() orelse return;
    if (tree.fullIf(otherwise) != null) return;
    if (empty(tree, branch.ast.then_expr)) return;
    if (!Written.sameTokens(tree, branch.ast.then_expr, otherwise)) return;
    try c.at(rule, branch.ast.if_token, "both bodies of this if are written alike: the condition decides nothing");
}

/// Whether a body is an empty block: two empty bodies are a placeholder, not a mistake.
fn empty(tree: *const Ast, body: Ast.Node.Index) bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, body) orelse return false;
    return statements.len == 0;
}

const breadth = @import("breadth.zig");

test "breadth: repeated condition: a chain's repeat reported, distinct conditions and a call not" {
    try breadth.expectFindings(check, "pub fn f(a: u32) u32 { if (a == 1) return 1 else if (a == 2) return 2 else if (a == 1) return 3; return 0; }", 1);
    try breadth.expectFindings(check, "pub fn f(a: u32) u32 { if (a == 1) return 1 else if (a == 2) return 2; return 0; }", 0);
    try breadth.expectFindings(check, "fn g() bool { return true; } pub fn f() u32 { if (g()) return 1 else if (g()) return 2; return 0; }", 0);
    // Two separate ifs are no chain.
    try breadth.expectFindings(check, "pub fn f(a: u32) u32 { if (a == 1) return 1; if (a == 1) return 2; return 0; }", 0);
}

test "breadth: identical bodies: reported where both are alike, not for a capture, an empty pair or an else-if" {
    try breadth.expectFindings(check, "pub fn f(a: bool) u32 { if (a) { return 1; } else { return 1; } }", 1);
    try breadth.expectFindings(check, "pub fn f(a: bool) u32 { return if (a) 2 else 2; }", 1);
    try breadth.expectFindings(check, "pub fn f(a: bool) u32 { return if (a) 2 else 3; }", 0);
    try breadth.expectFindings(check, "pub fn f(a: ?u32) u32 { return if (a) |v| v else 0; }", 0);
    try breadth.expectFindings(check, "pub fn f(a: bool) void { if (a) {} else {} }", 0);
    try breadth.expectFindings(check, "pub fn f(a: bool, b: bool) u32 { return if (a) 1 else if (b) 1 else 2; }", 0);
}
