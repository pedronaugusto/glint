//! Hygiene, opt-in: a declaration on a package's public surface with no doc comment. The surface
//! is read from the run's own module roots: each selected file a module import reaches (a
//! `--module NAME=FILE`), and each selected file no other file imports; then each file a `pub`
//! constant there imports whole (`pub const X = @import("x.zig");`), and so on. In those files, each
//! `pub` function, constant or variable whose every enclosing container is itself a `pub`
//! declaration (or the file) is on the surface; one with no `///` line before it is reported. A
//! declaration made public through a member of an import (`pub const X = @import("x.zig").Y;`)
//! is not followed: that file's other declarations are not on the surface, so none of it is read.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Rule = @import("Rule.zig").Rule;
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Facts = @import("Facts.zig");

pub fn check(c: *Context, rule: Rule) Context.Error!void {
    if (!try onSurface(c, c.file)) return;
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (!decl.public) continue;
        if (decl.kind != .function and decl.kind != .variable) continue;
        if (c.inTest(decl.token)) continue;
        const start = declarationNode(tree, model, decl);
        if (!publicPath(tree, model, start)) continue;
        const first = tree.firstToken(start);
        if (first > 0 and tree.tokenTag(first - 1) == .doc_comment) continue;
        try c.at(rule, decl.token, try c.allocator.print("public '{s}' has no doc comment", .{decl.name}));
    }
}

/// Whether `file` is on the run's public surface (the file's doc comment above).
fn onSurface(c: *Context, file: Project.FileId) Context.Error!bool {
    const project = c.project;
    var reached: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty;
    var next: std.ArrayList(Project.FileId) = .empty;
    for (project.sources) |*source| {
        if (!source.input.selected or source.input.kind != .zig) continue;
        var imported = false;
        var by_module = false;
        for (project.imports) |edge| if (edge.target == source.id) {
            imported = true;
            if (!std.mem.endsWith(u8, edge.spelling, ".zig")) by_module = true;
        };
        if (imported and !by_module) continue;
        try reached.put(c.allocator, source.id, {});
        try next.append(c.allocator, source.id);
    }
    while (next.pop()) |at| {
        if (at == file) return true;
        const source = project.at(at);
        if (source.file.status != .parsed) continue;
        const tree = &source.file.tree;
        for (source.model.declarations) |decl| {
            if (!decl.public or decl.kind != .variable) continue;
            const declared = tree.fullVarDecl(decl.node) orelse continue;
            const value = declared.ast.init_node.unwrap() orelse continue;
            if (!Facts.isBuiltin(tree, value, "@import")) continue;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(tree, value, &buffer);
            if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) continue;
            const literal = tree.tokenSlice(tree.nodeMainToken(args[0]));
            const target = project.imported(at, literal[1 .. literal.len - 1]) orelse continue;
            if (!project.at(target).input.selected) continue;
            if ((try reached.getOrPut(c.allocator, target)).found_existing) continue;
            try next.append(c.allocator, target);
        }
    }
    return false;
}

/// The node that starts a declaration's text: a function's `fn_decl` (its `pub` and prototype),
/// a variable's own.
fn declarationNode(tree: *const Ast, model: *const Model, decl: Model.Declaration) Ast.Node.Index {
    if (decl.kind == .function) if (model.parentOf(decl.node)) |parent| if (tree.nodeTag(parent) == .fn_decl) return parent;
    return decl.node;
}

/// Whether every container around `node` up to the file is the value of a `pub` declaration, and
/// no function body holds it.
fn publicPath(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var at = node;
    while (model.parentOf(at)) |parent| : (at = parent) {
        if (tree.nodeTag(parent) == .fn_decl) return false;
        var members: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&members, parent) == null) continue;
        // The container is a declaration's value: that declaration must be `pub`.
        const holder = model.parentOf(parent) orelse return true;
        const declared = tree.fullVarDecl(holder) orelse return false;
        if (declared.visib_token == null) return false;
    }
    return true;
}

const breadth = @import("breadth.zig");

test "breadth: doc comment: a public declaration on the surface without one reported; documented, private, nested in a private type not" {
    try breadth.expectFindings(check, "pub fn f() void {}\npub const x: u32 = 1;", 2);
    try breadth.expectFindings(check, "/// Does f.\npub fn f() void {}\n/// One.\npub const x: u32 = 1;", 0);
    try breadth.expectFindings(check, "fn f() void {}\nconst x: u32 = 1;", 0);
    try breadth.expectFindings(check, "/// S.\npub const S = struct {\n    pub fn g() void {}\n    /// Documented.\n    pub fn h() void {}\n};", 1);
    try breadth.expectFindings(check, "const S = struct {\n    pub fn g() void {}\n};\n/// Uses S.\npub fn f() void { S.g(); }", 0);
}

test "breadth: doc comment: a file only another file imports is on the surface only through a pub import" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, usize }{
        .{ "/// Lib.\npub const lib = @import(\"lib.zig\");", 1 },
        .{ "const lib = @import(\"lib.zig\");\n/// Uses lib.\npub fn f() void { lib.g(); }", 0 },
    };
    for (cases) |case| {
        var project = try Project.init(gpa, &.{
            .{ .name = "root.zig", .bytes = case[0] },
            .{ .name = "lib.zig", .bytes = "pub fn g() void {}" },
        }, &.{.{ .from = 0, .target = 1, .spelling = "lib.zig" }}, .{});
        defer project.deinit();
        var found = try breadth.run(gpa, &project, project.sources[1].id, check);
        defer found.deinit(gpa);
        try std.testing.expectEqual(case[1], found.messages.items.len);
    }
}
