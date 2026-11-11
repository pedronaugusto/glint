//! Hygiene, opt-in: a public declaration with no doc comment. Read: each `pub` function, constant
//! or variable at a container's level (not inside a function), whose first token is not preceded
//! by a `///` line. A re-export (`pub const X = y.X;`) is a declaration too: its doc says why it is
//! public here. TODO(0.8): the files a project marks as its public surface (default: every file).
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (!decl.public) continue;
        if (decl.kind != .function and decl.kind != .variable) continue;
        if (c.inTest(decl.token)) continue;
        // At a container's level: its parent chain meets a container before any function body.
        if (!containerLevel(tree, model, decl.node)) continue;
        const first = tree.firstToken(declarationNode(tree, model, decl));
        if (first > 0 and tree.tokenTag(first - 1) == .doc_comment) continue;
        try c.at(rule, decl.token, try c.allocator.print("public '{s}' has no doc comment", .{decl.name}));
    }
}

/// The node that starts a declaration's text: a function's `fn_decl` (its `pub` and prototype),
/// a variable's own.
fn declarationNode(tree: *const Ast, model: *const @import("Model.zig"), decl: @import("Model.zig").Declaration) Ast.Node.Index {
    if (decl.kind == .function) if (model.parentOf(decl.node)) |parent| if (tree.nodeTag(parent) == .fn_decl) return parent;
    return decl.node;
}

fn containerLevel(tree: *const Ast, model: *const @import("Model.zig"), node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl and at != tree.nodeData(parent).node_and_node[0]) return false;
        var members: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&members, parent) != null) return true;
    }
    // The file's own container.
    return true;
}

const breadth = @import("breadth.zig");

test "breadth: doc comment: a public declaration without one reported; documented, private, a function's own not" {
    try breadth.expectFindings(check, "pub fn f() void {}\npub const x: u32 = 1;", 2);
    try breadth.expectFindings(check, "/// Does f.\npub fn f() void {}\n/// One.\npub const x: u32 = 1;", 0);
    try breadth.expectFindings(check, "fn f() void {}\nconst x: u32 = 1;", 0);
    try breadth.expectFindings(check, "/// S.\npub const S = struct {\n    pub fn g() void {}\n    /// Documented.\n    pub fn h() void {}\n};", 1);
}
