//! Hygiene: an `errdefer` in a function that cannot return an error, so it never runs: its
//! written return type is a primitive (`void`, `u8`, `bool`, `noreturn`, …), a pointer, an
//! optional or an array of any type, none of which is an error union. A return type written by
//! a name that is not a primitive, or inferred (`!T`), or an error union, is not read. An
//! `errdefer` inside a nested function or a container's function is that function's.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Written = @import("Written.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"errdefer") continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var at = node;
        const function = while (model.parentOf(at)) |parent| : (at = parent) {
            if (tree.nodeTag(parent) == .fn_decl) break parent;
        } else continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, function) orelse continue;
        // `fn f() !T`: the `!` is a token before the return type, with no node of its own.
        const result = proto.ast.return_type.unwrap() orelse continue;
        if (tree.tokenTag(tree.firstToken(result) - 1) == .bang) continue;
        if (!neverError(tree, result)) continue;
        try c.at(rule, tree.nodeMainToken(node), "an errdefer in a function that cannot return an error: it never runs");
    }
}

/// Whether a written type is one no error union can be.
fn neverError(tree: *const Ast, node: Ast.Node.Index) bool {
    const at = Written.ungrouped(tree, node);
    switch (tree.nodeTag(at)) {
        .optional_type, .array_type, .array_type_sentinel => return true,
        .identifier => {
            if (Written.primitive(tree, at) != null) return true;
            const name = tree.tokenSlice(tree.nodeMainToken(at));
            for ([_][]const u8{ "void", "noreturn", "type", "anyopaque" }) |each| if (std.mem.eql(u8, name, each)) return true;
            return false;
        },
        else => return tree.fullPtrType(at) != null,
    }
}

const breadth = @import("breadth_test.zig");

test "breadth: dead errdefer: in a void, an integer or an optional function reported; an error union's not" {
    try breadth.expectFindings(check, "fn g() void {} pub fn f() void { errdefer g(); }", 1);
    try breadth.expectFindings(check, "fn g() void {} pub fn f() ?u8 { errdefer g(); return null; }", 1);
    try breadth.expectFindings(check, "fn g() void {} pub fn f() !void { errdefer g(); }", 0);
    try breadth.expectFindings(check, "fn g() void {} pub fn f() error{X}!u8 { errdefer g(); return 1; }", 0);
    try breadth.expectFindings(check, "const R = error{X}!u8; fn g() void {} pub fn f() R { errdefer g(); return 1; }", 0);
}
