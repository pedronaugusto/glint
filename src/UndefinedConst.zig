//! Hygiene: `const x: T = undefined;`: a constant is never written, so every read of it reads
//! undefined memory. A name read only inside `@TypeOf` (a type spelled through a value:
//! `@TypeOf(x.f)`) reads no value, and is not reported; nor is one never named at all (D001's).
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Model = @import("Model.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations, 0..) |decl, d| {
        if (decl.kind != .variable) continue;
        const declared = tree.fullVarDecl(decl.node) orelse continue;
        if (tree.tokenTag(declared.ast.mut_token) != .keyword_const) continue;
        const value = declared.ast.init_node.unwrap() orelse continue;
        if (tree.nodeTag(value) != .identifier or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "undefined")) continue;
        if (!readAsValue(tree, model, @fromBackingInt(@intCast(d)))) continue;
        try c.at(rule, decl.token, try c.allocator.print("constant '{s}' is `undefined` and never written: each read of it is undefined behaviour", .{decl.name}));
    }
}

/// Whether a reference to the declaration sits outside every `@TypeOf`.
fn readAsValue(tree: *const Ast, model: *const Model, decl: Model.Declaration.Id) bool {
    for (model.references) |reference| {
        if (reference.declaration != decl) continue;
        var at = reference.node;
        const typed = while (model.parentOf(at)) |parent| : (at = parent) {
            switch (tree.nodeTag(parent)) {
                .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
                    if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@TypeOf")) break true;
                },
                else => {},
            }
        } else false;
        if (!typed) return true;
    }
    return false;
}

const breadth = @import("breadth_test.zig");

test "breadth: undefined const: a constant read as a value reported; one read only in @TypeOf, or a var, not" {
    try breadth.expectFindings(check, "pub fn f() u32 { const x: u32 = undefined; return x; }", 1);
    try breadth.expectFindings(check, "const S = struct { f: u8 }; pub fn f() type { const x: S = undefined; return @TypeOf(x.f); }", 0);
    try breadth.expectFindings(check, "pub fn f() u32 { var x: u32 = undefined; x = 1; return x; }", 0);
}
