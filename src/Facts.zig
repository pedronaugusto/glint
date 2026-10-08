//! Conservative declaration and shape facts over the frozen AST/ZIR project.
//! Unknown comptime and cyclic aliases remain unknown; no spelling guesses.
const std = @import("std");
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Ast = std.zig.Ast;
const Facts = @This();

project: *const Project,
gpa: std.mem.Allocator,
cache: std.AutoHashMapUnmanaged(Key, Value) = .empty,
active: std.AutoHashMapUnmanaged(Key, void) = .empty,
remaining: usize = 100_000,

pub const Key = struct { file: Project.FileId, node: Ast.Node.Index };
pub const Decl = struct { file: Project.FileId, index: u32 };
pub const Container = struct { file: Project.FileId, scope: u32 };
pub const Unknown = enum { invalid_front_end, unresolved, missing_mapping, computed_import, comptime_dependent, cycle, budget, unsupported };
pub const Value = union(enum) {
    unknown: Unknown,
    primitive: []const u8,
    container: Container,
    instance: Container,
    function: Decl,
    pointer: *const Value,
    optional: *const Value,
    error_union: *const Value,
    error_set,
    scalar,

    pub fn known(self: Value) bool {
        return self != .unknown;
    }
};
pub const ResolveError = std.mem.Allocator.Error;

pub fn deinit(self: *Facts) void {
    self.cache.deinit(self.gpa);
    self.active.deinit(self.gpa);
    self.* = undefined;
}

pub fn resolve(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    if (self.project.files[@backingInt(file)].status != .parsed) return .{ .unknown = .invalid_front_end };
    const key: Key = .{ .file = file, .node = node };
    if (self.cache.get(key)) |value| return value;
    if (self.remaining == 0 or self.active.count() >= 128) return .{ .unknown = .budget };
    self.remaining -= 1;
    if (self.active.contains(key)) return .{ .unknown = .cycle };
    try self.active.put(self.gpa, key, {});
    defer _ = self.active.remove(key);
    const value = try self.resolveInner(file, node);
    try self.cache.put(self.gpa, key, value);
    return value;
}

fn boxed(self: *Facts, value: Value) ResolveError!*const Value {
    // The caller gives a scratch arena. Values and memoized facts share its lifetime.
    const box = try self.gpa.create(Value);
    box.* = value;
    return box;
}

fn resolveInner(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const index = @backingInt(file);
    const tree = &self.project.files[index].tree;
    const model = &self.project.models[index];
    const tag = tree.nodeTag(node);
    switch (tag) {
        .identifier => {
            const ref = model.reference(node) orelse return .{ .unknown = .unresolved };
            if (ref.declaration) |decl| return self.declaration(.{ .file = file, .index = decl });
            const name = tree.tokenSlice(ref.token);
            if (Model.primitive(name)) return .{ .primitive = name };
            return .{ .unknown = .unresolved };
        },
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            const lhs = try self.resolve(file, data[0]);
            const name = tree.tokenSlice(data[1]);
            const container = switch (lhs) {
                .container, .instance => |c| c,
                .pointer => |p| switch (p.*) {
                    .instance, .container => |c| c,
                    else => return .{ .unknown = .unsupported },
                },
                else => return .{ .unknown = .unresolved },
            };
            if (self.member(container, name)) |decl| return self.declaration(decl);
            return .{ .unknown = .unresolved };
        },
        .optional_type => return .{ .optional = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        .error_union => return .{ .error_union = try self.boxed(try self.resolve(file, tree.nodeData(node).node_and_node[1])) },
        .error_set_decl, .merge_error_sets => return .error_set,
        .number_literal, .string_literal, .char_literal, .enum_literal => return .scalar,
        else => {},
    }
    if (tree.fullPtrType(node)) |ptr| return .{ .pointer = try self.boxed(try self.resolve(file, ptr.ast.child_type)) };
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, node) != null) {
        for (model.scopes, 0..) |scope, s| if (scope.kind == .container and scope.node == node) return .{ .container = .{ .file = file, .scope = @intCast(s) } };
    }
    switch (tag) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            const args = builtinArgs(tree, node, &buffer);
            if (std.mem.eql(u8, name, "@import")) {
                if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return .{ .unknown = .computed_import };
                const spelling = std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidLiteral => return .{ .unknown = .computed_import },
                };
                const target = self.project.imported(file, spelling) orelse return .{ .unknown = .missing_mapping };
                return .{ .container = .{ .file = target, .scope = 0 } };
            }
            if (std.mem.eql(u8, name, "@This")) {
                var scope: ?u32 = model.token_scopes[tree.nodeMainToken(node)];
                while (scope) |s| {
                    if (model.scopes[s].kind == .container or model.scopes[s].kind == .file) return .{ .container = .{ .file = file, .scope = s } };
                    scope = model.scopes[s].parent;
                }
            }
            if (std.mem.eql(u8, name, "@as") and args.len == 2) return instance(try self.resolve(file, args[0]));
            return .{ .unknown = .comptime_dependent };
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node).?;
            const callee = try self.resolve(file, call.ast.fn_expr);
            if (callee == .function) {
                const decl = callee.function;
                const declaration_record = self.project.models[@backingInt(decl.file)].declarations[decl.index];
                const target_tree = &self.project.files[@backingInt(decl.file)].tree;
                var fn_buffer: [1]Ast.Node.Index = undefined;
                const function = target_tree.fullFnProto(&fn_buffer, declaration_record.node).?;
                const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
                const result = try self.resolve(decl.file, result_node);
                if (result == .primitive and std.mem.eql(u8, result.primitive, "type")) return .{ .unknown = .comptime_dependent };
                return instance(result);
            }
            return .{ .unknown = .unresolved };
        },
        .struct_init_one, .struct_init_one_comma, .struct_init, .struct_init_comma => {
            const value = tree.fullStructInit(&buffer, node).?;
            if (value.ast.type_expr.unwrap()) |t| return instance(try self.resolve(file, t));
            return .{ .unknown = .unsupported };
        },
        .address_of => return .{ .pointer = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        .deref => {
            const lhs = try self.resolve(file, tree.nodeData(node).node);
            return if (lhs == .pointer) lhs.pointer.* else .{ .unknown = .unsupported };
        },
        .@"try" => {
            const lhs = try self.resolve(file, tree.nodeData(node).node);
            return if (lhs == .error_union) lhs.error_union.* else .{ .unknown = .unsupported };
        },
        else => return .{ .unknown = .unsupported },
    }
}

pub fn declaration(self: *Facts, decl: Decl) ResolveError!Value {
    const model = &self.project.models[@backingInt(decl.file)];
    const declaration_record = model.declarations[decl.index];
    const tree = &self.project.files[@backingInt(decl.file)].tree;
    if (declaration_record.kind == .function) return .{ .function = decl };
    if (declaration_record.kind == .parameter) return instance(try self.resolve(decl.file, declaration_record.node));
    if (declaration_record.kind == .capture) return .{ .unknown = .comptime_dependent };
    if (declaration_record.kind == .field) {
        const field = tree.fullContainerField(declaration_record.node).?;
        if (field.ast.type_expr.unwrap()) |t| return instance(try self.resolve(decl.file, t));
        return .{ .unknown = .unsupported };
    }
    if (tree.fullVarDecl(declaration_record.node)) |variable| {
        if (variable.ast.type_node.unwrap()) |t| {
            const type_value = try self.resolve(decl.file, t);
            if (type_value != .primitive or !std.mem.eql(u8, type_value.primitive, "type")) return instance(type_value);
        }
        if (variable.ast.init_node.unwrap()) |value| return self.resolve(decl.file, value);
    }
    return .{ .unknown = .unsupported };
}

pub fn member(self: *const Facts, container: Container, name: []const u8) ?Decl {
    const model = &self.project.models[@backingInt(container.file)];
    if (model.scopes[container.scope].names.get(name)) |decl| return .{ .file = container.file, .index = decl };
    for (model.declarations, 0..) |decl, i| if (decl.kind == .field and decl.scope == container.scope and std.mem.eql(u8, decl.name, name)) return .{ .file = container.file, .index = @intCast(i) };
    return null;
}

pub fn definition(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Decl {
    const tree = &self.project.files[@backingInt(file)].tree;
    if (tree.nodeTag(node) == .identifier) {
        const ref = self.project.models[@backingInt(file)].reference(node) orelse return null;
        return if (ref.declaration) |decl| .{ .file = file, .index = decl } else null;
    }
    if (tree.nodeTag(node) == .field_access) {
        const data = tree.nodeData(node).node_and_token;
        const value = try self.resolve(file, data[0]);
        const container = switch (value) {
            .container, .instance => |c| c,
            .pointer => |p| switch (p.*) {
                .container, .instance => |c| c,
                else => return null,
            },
            else => return null,
        };
        return self.member(container, tree.tokenSlice(data[1]));
    }
    return null;
}

fn instance(value: Value) Value {
    return switch (value) {
        .container => |c| .{ .instance = c },
        else => value,
    };
}

pub fn builtinArgs(tree: *const Ast, node: Ast.Node.Index, buffer: *[2]Ast.Node.Index) []const Ast.Node.Index {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma => blk: {
            var count: usize = 0;
            inline for (tree.nodeData(node).opt_node_and_opt_node) |item| if (item.unwrap()) |arg| {
                buffer[count] = arg;
                count += 1;
            };
            break :blk buffer[0..count];
        },
        .builtin_call, .builtin_call_comma => blk: {
            const range = tree.nodeData(node).extra_range;
            break :blk tree.extraDataSlice(range, Ast.Node.Index);
        },
        else => &.{},
    };
}

test "facts aliases cycles and absent module mappings stay unknown" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const A = B; const B = A; const dep = @import(\"missing\");" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const first = project.files[0].tree.fullVarDecl(project.models[0].declarations[0].node).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(Unknown.cycle, (try facts.resolve(@fromBackingInt(0), first)).unknown);
    const dep = project.files[0].tree.fullVarDecl(project.models[0].declarations[2].node).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(Unknown.missing_mapping, (try facts.resolve(@fromBackingInt(0), dep)).unknown);
}
