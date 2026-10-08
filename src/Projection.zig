//! Architecture consumers project this same frozen Zig model; no path or graph policy.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Projection = @This();
arena: std.heap.ArenaAllocator,
snapshot: u64,
imports: []const Import,
calls: []const Call,
references: []const Reference,
complete: bool,

pub const Context = enum { production, @"test", @"comptime", may_be_production };
pub const Import = struct { file: Project.FileId, node: Project.NodeId, spelling: ?[]const u8, target: ?Project.FileId, context: Context, unknown: ?Facts.Unknown };
pub const Call = struct { file: Project.FileId, node: Project.NodeId, definition: ?Facts.Decl, context: Context, unknown: ?Facts.Unknown, instruction: ?std.zig.Zir.Inst.Index };
pub const Reference = struct { file: Project.FileId, node: Project.NodeId, definition: ?Facts.Decl, context: Context, unknown: ?Facts.Unknown };
pub const InitError = Facts.ResolveError;
/// Unknown graph facts are explicit and make complete false. No exact graph is invented.
pub fn init(gpa: std.mem.Allocator, project: *const Project, budget: usize) InitError!Projection {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var facts: Facts = .{ .project = project, .gpa = a, .remaining = budget };
    defer facts.deinit();
    var imports: std.ArrayList(Import) = .empty;
    var calls: std.ArrayList(Call) = .empty;
    var references: std.ArrayList(Reference) = .empty;
    var complete = true;
    for (project.files, 0..) |*file, i| {
        const id = Project.FileId.fromRaw(@intCast(i)); // safe: project construction bounds source count.
        const model = &project.models[i];
        if (file.status != .parsed) {
            complete = false;
            continue;
        }
        for (model.import_nodes) |node| {
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(&file.tree, node, &buffer);
            const value = try facts.resolve(id, node);
            var spelling: ?[]const u8 = null;
            if (args.len == 1 and file.tree.nodeTag(args[0]) == .string_literal) spelling = std.zig.string_literal.parseAlloc(a, file.tree.tokenSlice(file.tree.nodeMainToken(args[0]))) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
            const unknown = if (value == .unknown) value.unknown else null;
            if (unknown != null) complete = false;
            try imports.append(a, .{ .file = id, .node = Project.NodeId.fromRaw(@backingInt(node)), .spelling = spelling, .target = if (value == .container) value.container.file else null, .context = context(project, id, file.tree.nodeMainToken(node)), .unknown = unknown }); // safe: std AST node identity fits u32.
        }
        for (file.tree.nodes.items(.tag), 0..) |tag, n| {
            const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: budgeted AST inventory.
            const ctx = context(project, id, file.tree.nodeMainToken(node));
            if (tag == .identifier or tag == .field_access) {
                if (tag == .identifier and Model.primitive(file.tree.tokenSlice(file.tree.nodeMainToken(node)))) continue;
                const definition = try facts.definition(id, node);
                const value = if (definition == null) try facts.resolve(id, node) else Facts.Value.scalar;
                const unknown: ?Facts.Unknown = if (definition == null and value == .unknown) value.unknown else null;
                try references.append(a, .{ .file = id, .node = Project.NodeId.fromRaw(@backingInt(node)), .definition = definition, .context = ctx, .unknown = unknown }); // safe: std AST node identity fits u32.
            }
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call = file.tree.fullCall(&buffer, node) orelse continue;
            const value = try facts.resolve(id, call.ast.fn_expr);
            const operation = model.node_operations[n];
            const unknown: ?Facts.Unknown = if (operation == null) .unsupported else if (value == .unknown) value.unknown else if (value != .function) .unsupported else null;
            if (unknown != null) complete = false;
            try calls.append(a, .{ .file = id, .node = Project.NodeId.fromRaw(@backingInt(node)), .definition = if (value == .function) value.function else null, .context = ctx, .unknown = unknown, .instruction = if (operation) |op| model.operations[op].instruction else null }); // safe: std AST node identity fits u32.
        }
    }
    if (facts.remaining == 0) complete = false;
    return .{ .arena = arena, .snapshot = project.identity, .imports = imports.items, .calls = calls.items, .references = references.items, .complete = complete };
}
pub fn deinit(self: *Projection) void {
    self.arena.deinit();
    self.* = undefined;
}
/// Context belongs to the importing use, including nested tests and lazy source.
pub fn context(project: *const Project, file: Project.FileId, token: std.zig.Ast.TokenIndex) Context {
    if (project.inputs[file.raw()].classification == .@"test") return .@"test";
    const model = &project.models[file.raw()];
    var scope: ?u32 = model.token_scopes[token];
    var comptime_seen = false;
    var conditional_seen = false;
    while (scope) |s| {
        switch (model.scopes[s].kind) {
            .@"test" => return .@"test",
            .@"comptime" => comptime_seen = true,
            .branch => conditional_seen = true,
            else => {},
        }
        scope = model.scopes[s].parent;
    }
    return if (conditional_seen) .may_be_production else if (comptime_seen) .@"comptime" else .production;
}
