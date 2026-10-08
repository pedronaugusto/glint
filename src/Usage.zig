//! Conservative ZIR-backed project reference relation, independent of rule admission.
const std = @import("std");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Ast = std.zig.Ast;
const Usage = @This();
arena: std.heap.ArenaAllocator,
referenced: []const []const bool,
complete: bool,

pub fn init(gpa: std.mem.Allocator, project: *const Project, facts: *Facts) Facts.ResolveError!Usage {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const used = try a.alloc([]bool, project.files.len);
    for (project.models, 0..) |model, i| {
        used[i] = try a.alloc(bool, model.declarations.len);
        @memset(used[i], false);
    }
    var undecided = false;
    for (project.files, 0..) |*file, i| {
        const id = Project.FileId.fromRaw(@intCast(i)); // safe: checked project file inventory.
        const model = &project.models[i];
        if (file.status != .parsed or model.lowered_coverage == .budget_exhausted) {
            undecided = true;
            continue;
        }
        for (model.import_nodes) |node| if ((try facts.resolve(id, node)) == .unknown) {
            undecided = true;
        };
        for (model.references) |reference| if (reference.declaration) |d| {
            used[i][d] = true;
            const declaration = model.declarations[d];
            if (model.scopes[declaration.scope].kind != .file and model.scopes[declaration.scope].kind != .container) continue;
            var witnessed = false;
            for (model.zir_references) |lowered| if (lowered.token == reference.token and lowered.declaration == d) {
                witnessed = true;
                break;
            };
            if (!witnessed) undecided = true;
        } else if (reference.unknown != null and reference.unknown.? != .primitive) {
            undecided = true;
        };
        for (model.declarations, 0..) |decl, d| {
            if (decl.kind == .function) {
                var function_buffer: [1]Ast.Node.Index = undefined;
                const function = file.tree.fullFnProto(&function_buffer, decl.node).?;
                var parameters = function.iterate(&file.tree);
                while (parameters.next()) |parameter| {
                    if (parameter.anytype_ellipsis3 != null) undecided = true;
                    if (parameter.comptime_noalias) |token| if (file.tree.tokenTag(token) == .keyword_comptime) {
                        undecided = true;
                    };
                }
            }
            if (!decl.public and !decl.exported) continue;
            used[i][d] = true;
            if (decl.kind == .function) {
                var function_buffer: [1]Ast.Node.Index = undefined;
                const function = file.tree.fullFnProto(&function_buffer, decl.node).?;
                if (function.ast.return_type.unwrap()) |ret| {
                    const value = try facts.resolve(id, ret);
                    if (value == .unknown) undecided = true else retain(used, value, project);
                }
                var parameters = function.iterate(&file.tree);
                while (parameters.next()) |parameter| if (parameter.type_expr) |node| {
                    const value = try facts.resolve(id, node);
                    if (value == .unknown) undecided = true else retain(used, value, project);
                };
            }
            if (decl.kind == .variable) retain(used, try facts.declaration(.{ .file = id, .index = @intCast(d) }), project); // safe: checked declaration inventory.
        }
        for (file.tree.nodes.items(.tag), 0..) |tag, n| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(n)); // safe: checked AST inventory.
            if (tag == .field_access) {
                var witnessed = model.node_operations[n] != null;
                if (!witnessed) if (model.node_parents[n]) |parent| {
                    if (model.node_operations[@backingInt(parent)]) |op| witnessed = model.operations[op].kind == .member_call; // safe: checked AST parent index.
                };
                const definition = try facts.definition(id, node);
                if (!witnessed or definition == null) {
                    undecided = true;
                    continue;
                }
                used[definition.?.file.raw()][definition.?.index] = true;
            }
            var call_buffer: [1]Ast.Node.Index = undefined;
            if (file.tree.fullCall(&call_buffer, node)) |call| {
                if (model.node_operations[n] == null) {
                    undecided = true;
                    continue;
                }
                const value = try facts.resolve(id, call.ast.fn_expr);
                if (value != .function) {
                    undecided = true;
                    continue;
                }
                used[value.function.file.raw()][value.function.index] = true;
                // Passing a container can invoke language/library hooks. Retain its entire
                // declaration set without guessing hook names or the callee's effects.
                for (call.ast.params) |arg| {
                    const parameter = try facts.resolve(id, arg);
                    if (parameter == .unknown) {
                        undecided = true;
                        continue;
                    }
                    retain(used, parameter, project);
                }
            }
            var buffer: [2]Ast.Node.Index = undefined;
            const args = Facts.builtinArgs(&file.tree, node, &buffer);
            const name = file.tree.tokenSlice(file.tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "@field") or std.mem.eql(u8, name, "@hasDecl")) {
                if (model.node_operations[n] == null) {
                    undecided = true;
                    continue;
                }
                if (try facts.reflected(id, node)) |definition| used[definition.file.raw()][definition.index] = true else undecided = true;
            } else if (std.mem.eql(u8, name, "@typeInfo")) {
                if (args.len != 1 or model.node_operations[n] == null) {
                    undecided = true;
                    continue;
                }
                const value = try facts.resolve(id, args[0]);
                if (value == .unknown or (value == .container and value.container.symbolic)) undecided = true else retain(used, value, project);
            } else if (std.mem.eql(u8, name, "@call") or std.mem.eql(u8, name, "@Type") or std.mem.eql(u8, name, "@export") or std.mem.eql(u8, name, "@extern")) undecided = true;
        }
    }
    return .{ .arena = arena, .referenced = used, .complete = !undecided };
}
pub fn deinit(self: *Usage) void {
    self.arena.deinit();
    self.* = undefined;
}
fn retain(used: [][]bool, value: Facts.Value, project: *const Project) void {
    const container = switch (value) {
        .container, .instance => |c| c,
        .pointer, .optional, .error_union => |child| return retain(used, child.*, project),
        else => return,
    };
    for (project.models[container.file.raw()].declarations, 0..) |decl, i| if (decl.scope == container.scope) {
        used[container.file.raw()][i] = true;
    };
    // A container can expose nested namespaces to a compiler hook. Retain all
    // descendant declarations instead of guessing which hook traverses them.
    const model = &project.models[container.file.raw()];
    for (model.declarations, 0..) |decl, i| {
        var scope: ?u32 = decl.scope;
        while (scope) |s| {
            if (s == container.scope) {
                used[container.file.raw()][i] = true;
                break;
            }
            scope = model.scopes[s].parent;
        }
    }
}
