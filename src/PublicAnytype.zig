//! Hygiene, opt-in (libraries): a parameter declared `anytype` in a public function's signature.
//! Its type is whatever each caller passes, so the signature promises nothing a caller can check
//! and any change to the body may break one. Read: each `pub fn` whose every enclosing container
//! is itself a `pub` declaration (or the file), and each of its parameters written `anytype`.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Model = @import("Model.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (!decl.public or decl.kind != .function or c.inTest(decl.token)) continue;
        if (!publicPath(tree, model, decl.node)) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, decl.node) orelse continue;
        var it = proto.iterate(tree);
        while (it.next()) |param| {
            const token = param.anytype_ellipsis3 orelse continue;
            if (tree.tokenTag(token) != .keyword_anytype) continue;
            try c.at(rule, token, try c.allocator.print("public '{s}' takes `anytype`: its signature states no type a caller can check", .{decl.name}));
        }
    }
}

/// Whether every container around `node` up to the file is the value of a `pub` declaration, and
/// no function body holds it.
fn publicPath(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl and at != tree.nodeData(parent).node_and_node[0]) return false;
        var members: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&members, parent) == null) continue;
        const holder = model.parentOf(parent) orelse return true;
        const declared = tree.fullVarDecl(holder) orelse return false;
        if (declared.visib_token == null) return false;
    }
    return true;
}

const breadth = @import("breadth_test.zig");

test "breadth: public anytype: a public function's anytype parameter reported; a private one's, a typed one not" {
    try breadth.expectFindings(check, "pub fn f(a: anytype, b: u8) void { _ = a; _ = b; }", 1);
    try breadth.expectFindings(check, "fn f(a: anytype) void { _ = a; }", 0);
    try breadth.expectFindings(check, "pub fn f(a: u8) void { _ = a; }", 0);
    try breadth.expectFindings(check, "const S = struct { pub fn f(a: anytype) void { _ = a; } };", 0);
}
