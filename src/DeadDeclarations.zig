//! Deadness needs actual lowered references, member operations and explicit reflective retention.
const std = @import("std");
const Context = @import("RuleContext.zig");

pub fn check(context: *Context) Context.Error!void {
    if (!context.config.has(.D001)) return;
    const project = context.project;
    const usage = context.usage orelse return context.undecided(.D001, 0, .unsupported, "project reference model not available");
    const used = usage.referenced;
    if (!usage.complete) return context.undecided(.D001, 0, .unresolved, "deadness withheld: a ZIR reference, member call, compiler-hook escape or reflection is unresolved");
    const index = context.file.raw();
    const model = &project.models[index];
    const tree = &project.files[index].tree;
    for (model.declarations, 0..) |decl, d| {
        if (decl.public or decl.exported or used[index][d] or decl.lowered == null) continue;
        if (decl.kind != .function and decl.kind != .variable) continue;
        if (model.scopes[decl.scope].kind != .file and model.scopes[decl.scope].kind != .container) continue;
        if (decl.kind == .variable) {
            const init = tree.fullVarDecl(decl.node).?.ast.init_node.unwrap() orelse continue;
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "@import")) continue; // Z013 is the import case, one predicate owner.
        }
        try context.at(.D001, decl.token, try context.allocator.print("private declaration '{s}' has no resolved reference; no unresolved member/hook/reflection use was ignored", .{decl.name}));
    }
}
