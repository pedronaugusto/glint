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
publications: std.AutoHashMapUnmanaged(usize, *const Publication) = .empty,
templates: std.AutoHashMapUnmanaged(Decl, ?Value) = .empty,
remaining: usize = 100_000,

pub const Key = struct { file: Project.FileId, node: Ast.Node.Index };
pub const Decl = struct { file: Project.FileId, index: u32 };
pub const Container = struct { file: Project.FileId, scope: u32, symbolic: bool = false };
/// A library's declarations in this project, found through its modules' roots. Roles are the
/// caller's enum values; the resolver never interprets them.
pub const Publication = struct {
    entries: []const Entry,
    /// Required members that did not resolve: drift or a missing module mapping, never silence.
    gaps: []const Gap,
    /// Every file the library's own roots reach, std and builtin aside.
    files: []const Project.FileId,
};
pub const Entry = struct { role: u32, target: Target };
pub const Target = union(enum) { function: Decl, container: Container };
pub const Gap = struct { module: []const u8, path: []const u8, why: Unknown };
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
pub const ResolveError = Model.InitError;

pub fn deinit(self: *Facts) void {
    self.cache.deinit(self.gpa);
    self.active.deinit(self.gpa);
    self.publications.deinit(self.gpa);
    self.templates.deinit(self.gpa);
    self.* = undefined;
}

/// Finds what `library` publishes: each module's root is every file the project maps that
/// module's name to, and each member is the declaration its path names from that root. Found
/// once per run and shared by every rule.
pub fn publication(self: *Facts, library: anytype) ResolveError!*const Publication {
    const key = @intFromPtr(library.modules.ptr); // safe: the address names the library only for this run, which the caller keeps alive.
    if (self.publications.get(key)) |found| return found;
    var entries: std.ArrayList(Entry) = .empty;
    var gaps: std.ArrayList(Gap) = .empty;
    const reached = try self.gpa.alloc(bool, self.project.count());
    @memset(reached, false);
    for (library.modules) |module| {
        for (self.project.imports, 0..) |mapping, index| {
            if (!std.mem.eql(u8, mapping.spelling, module.name)) continue;
            // Many files import one root; its members are found once.
            var repeated = false;
            for (self.project.imports[0..index]) |earlier| if (std.mem.eql(u8, earlier.spelling, module.name) and earlier.target.eql(mapping.target)) {
                repeated = true;
            };
            if (repeated) continue;
            reached[mapping.target.raw()] = true; // safe: validated mapping targets index the frozen file table.
            for (module.members) |listed| switch (try self.published(mapping.target, listed.path)) {
                .found => |target| {
                    const role_value: u32 = @intCast(@backingInt(listed.role)); // safe: a role enum's values are small by construction.
                    try entries.append(self.gpa, .{ .role = role_value, .target = target });
                    // The container a type function returns is also its type: instances declared with it are the role's.
                    if (target == .function) if (try self.template(target.function)) |returned| if (returned == .container) {
                        try entries.append(self.gpa, .{ .role = role_value, .target = .{ .container = .{ .file = returned.container.file, .scope = returned.container.scope } } });
                    };
                },
                .gap => |why| if (listed.required) try gaps.append(self.gpa, .{ .module = module.name, .path = listed.path, .why = why }),
            };
        }
    }
    var growing = true;
    while (growing) {
        growing = false;
        for (self.project.imports) |mapping| {
            if (!reached[mapping.from.raw()] or reached[mapping.target.raw()]) continue; // safe: validated mapping identities index the frozen file table.
            if (std.mem.eql(u8, mapping.spelling, "std") or std.mem.eql(u8, mapping.spelling, "builtin") or std.mem.eql(u8, mapping.spelling, "root")) continue;
            reached[mapping.target.raw()] = true; // safe: validated mapping identities index the frozen file table.
            growing = true;
        }
    }
    var files: std.ArrayList(Project.FileId) = .empty;
    for (reached, 0..) |in_library, index| if (in_library) try files.append(self.gpa, Project.FileId.fromRaw(@intCast(index))); // safe: the project bounds its file count to u32 identities.
    const result = try self.gpa.create(Publication);
    result.* = .{ .entries = entries.items, .gaps = gaps.items, .files = files.items };
    try self.publications.put(self.gpa, key, result);
    return result;
}

const Found = union(enum) { found: Target, gap: Unknown };
/// Walks public namespaces from a module root, the way a program names the declaration.
fn published(self: *Facts, root: Project.FileId, path: []const u8) ResolveError!Found {
    var current: Value = .{ .container = .{ .file = root, .scope = 0 } };
    var names = std.mem.splitScalar(u8, path, '.');
    while (names.next()) |name| {
        const container = switch (current) {
            .container, .instance => |c| c,
            .unknown => |why| return .{ .gap = why },
            else => return .{ .gap = .unsupported },
        };
        const decl = self.member(container, name) orelse return .{ .gap = .unresolved };
        if (!self.project.models[decl.file.raw()].declarations[decl.index].public) return .{ .gap = .unresolved }; // safe: enum identities index their owning frozen tables without narrowing.
        current = try self.declaration(decl);
    }
    return switch (current) {
        .function => |decl| .{ .found = .{ .function = decl } },
        .container => |c| .{ .found = .{ .container = .{ .file = c.file, .scope = c.scope } } },
        .unknown => |why| .{ .gap = why },
        else => .{ .gap = .unsupported },
    };
}

/// The role `library` publishes for a function declaration, or a type or instance of a
/// published container, seen through pointers, optionals and error unions.
pub fn role(self: *Facts, library: anytype, value: Value) ResolveError!?@TypeOf(library).Role {
    const Role = @TypeOf(library).Role;
    const found = try self.publication(library);
    var current = value;
    while (true) switch (current) {
        .pointer, .optional, .error_union => |inner| current = inner.*,
        .function => |decl| {
            for (found.entries) |entry| if (entry.target == .function and std.meta.eql(entry.target.function, decl)) return @as(Role, @fromBackingInt(@intCast(entry.role))); // safe: the entry holds a role value of this enum.
            return null;
        },
        .container, .instance => |c| {
            for (found.entries) |entry| if (entry.target == .container and entry.target.container.file.eql(c.file) and entry.target.container.scope == c.scope) return @as(Role, @fromBackingInt(@intCast(entry.role))); // safe: the entry holds a role value of this enum.
            return null;
        },
        else => return null,
    };
}

pub fn resolve(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    if (self.project.files[file.raw()].status != .parsed) return .{ .unknown = .invalid_front_end }; // safe: enum identities index their owning frozen tables without narrowing.
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
    const index = file.raw(); // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[index].tree;
    const model = &self.project.models[index];
    const tag = tree.nodeTag(node);
    switch (tag) {
        .identifier, .test_decl => {
            const ref = model.reference(node) orelse return .{ .unknown = .unresolved };
            if (ref.declaration) |decl| return self.declaration(.{ .file = file, .index = decl });
            const name = tree.tokenSlice(ref.token);
            if (Model.primitive(name)) return .{ .primitive = name };
            return .{ .unknown = .unresolved };
        },
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            const lhs = try self.resolve(file, data[0]);
            const name = try self.memberName(tree.tokenSlice(data[1]));
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
        .enum_literal => return .{ .unknown = .comptime_dependent },
        .number_literal, .string_literal, .char_literal => return .scalar,
        else => {},
    }
    if (tree.fullPtrType(node)) |ptr| return .{ .pointer = try self.boxed(try self.resolve(file, ptr.ast.child_type)) };
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, node) != null) {
        for (model.scopes, 0..) |scope, s| if (scope.kind == .container and scope.node == node) return .{ .container = .{ .file = file, .scope = @intCast(s) } }; // safe: scope indexes come from the bounded frozen per-file model.
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
            if ((std.mem.eql(u8, name, "@field") or std.mem.eql(u8, name, "@hasDecl")) and args.len == 2) {
                const target = (try self.reflected(file, node)) orelse return .{ .unknown = .comptime_dependent };
                if (std.mem.eql(u8, name, "@hasDecl")) return .scalar;
                return self.declaration(target);
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
                const declaration_record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
                const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
                var fn_buffer: [1]Ast.Node.Index = undefined;
                const function = target_tree.fullFnProto(&fn_buffer, declaration_record.node).?;
                const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
                const result = try self.resolve(decl.file, result_node);
                if (result == .primitive and std.mem.eql(u8, result.primitive, "type")) {
                    var value = try self.template(decl) orelse return .{ .unknown = .comptime_dependent };
                    if (value == .container) value.container.symbolic = function.ast.params.len != 0;
                    return value;
                }
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

/// The container a type function returns when its body ends in one `return` of that container,
/// whatever comptime checks come before. This is the template, not an instantiation: no
/// arguments are evaluated.
pub fn template(self: *Facts, decl: Decl) ResolveError!?Value {
    if (self.templates.get(decl)) |known| return known;
    const found = try self.findTemplate(decl);
    try self.templates.put(self.gpa, decl, found);
    return found;
}
fn findTemplate(self: *Facts, decl: Decl) ResolveError!?Value {
    const record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const lowered = record.lowered orelse return null;
    var fn_node = self.project.files[decl.file.raw()].zir.?.getDeclaration(lowered).src_node; // safe: enum identities index their owning frozen tables without narrowing.
    if (tree.nodeTag(fn_node) != .fn_decl) fn_node = self.project.models[decl.file.raw()].node_parents[@backingInt(fn_node)] orelse return null; // safe: enum identities index their owning frozen tables without narrowing.
    if (tree.nodeTag(fn_node) != .fn_decl) return null;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return null;
    if (statements.len == 0 or tree.nodeTag(statements[statements.len - 1]) != .@"return") return null;
    const last = statements[statements.len - 1];
    // Only the final statement may return. A `return` in the checks before it, in a branch or a
    // nested block, could return something else. Those after it are inside the returned container,
    // where only nested functions can contain one.
    for (tree.firstToken(body)..tree.nodeMainToken(last)) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_return) return null; // safe: the body's token range lies inside the file's token table.
    }
    const returned = tree.nodeData(last).opt_node.unwrap() orelse return null;
    var container_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_buffer, returned) == null) return null;
    const value = try self.resolve(decl.file, returned);
    return value;
}

pub fn declaration(self: *Facts, decl: Decl) ResolveError!Value {
    const model = &self.project.models[decl.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const declaration_record = model.declarations[decl.index];
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (declaration_record.kind == .function) return .{ .function = decl };
    if (declaration_record.kind == .parameter) {
        const value = try self.resolve(decl.file, declaration_record.node);
        if (value == .primitive and std.mem.eql(u8, value.primitive, "type")) return .{ .unknown = .comptime_dependent };
        return instance(value);
    }
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

fn memberName(self: *Facts, raw: []const u8) ResolveError![]const u8 {
    return Model.identifier(self.gpa, raw);
}

pub fn member(self: *const Facts, container: Container, name: []const u8) ?Decl {
    const model = &self.project.models[container.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    if (model.scopes[container.scope].names.get(name)) |decl| return .{ .file = container.file, .index = decl };
    for (model.declarations, 0..) |decl, i| if (decl.kind == .field and decl.scope == container.scope and std.mem.eql(u8, decl.name, name)) return .{ .file = container.file, .index = @intCast(i) }; // safe: scope indexes come from the bounded frozen per-file model.
    return null;
}

pub fn definition(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Decl {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (tree.nodeTag(node) == .identifier or tree.nodeTag(node) == .test_decl) {
        const ref = self.project.models[file.raw()].reference(node) orelse return null; // safe: enum identities index their owning frozen tables without narrowing.
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
        return self.member(container, try self.memberName(tree.tokenSlice(data[1])));
    }
    return null;
}

/// Literal reflection binds a declaration only on a concrete, resolved container.
pub fn reflected(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Decl {
    const tree = &self.project.files[file.raw()].tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, node, &buffer);
    if (args.len != 2 or tree.nodeTag(args[1]) != .string_literal) return null;
    const value = try self.resolve(file, args[0]);
    const container = switch (value) {
        .container, .instance => |c| c,
        else => return null,
    };
    if (container.symbolic) return null;
    const name = std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(args[1]))) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return self.member(container, name);
}

/// Follows only declaration aliases, keeping the final declaration's provenance.
/// Cycles, computed expressions and unsupported comptime retain uncertainty.
pub fn origin(self: *Facts, start: Decl) ResolveError!?Decl {
    var current = start;
    var visited: [128]Decl = undefined;
    var count: usize = 0;
    while (count < visited.len) {
        for (visited[0..count]) |earlier| if (std.meta.eql(earlier, current)) return null;
        visited[count] = current;
        count += 1;
        const record = self.project.models[current.file.raw()].declarations[current.index]; // safe: declaration identities index their owning frozen model.
        if (record.kind != .variable) return current;
        const tree = &self.project.files[current.file.raw()].tree; // safe: declaration identities index their owning frozen file table.
        const variable = tree.fullVarDecl(record.node).?;
        const expr = variable.ast.init_node.unwrap() orelse return current;
        if (tree.nodeTag(expr) != .identifier and tree.nodeTag(expr) != .field_access) return current;
        current = (try self.definition(current.file, expr)) orelse return null;
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
    try std.testing.expectEqual(Unknown.cycle, (try facts.resolve(Project.FileId.fromRaw(0), first)).unknown); // safe: scope indexes come from the bounded frozen per-file model.
    const dep = project.files[0].tree.fullVarDecl(project.models[0].declarations[2].node).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(Unknown.missing_mapping, (try facts.resolve(Project.FileId.fromRaw(0), dep)).unknown); // safe: scope indexes come from the bounded frozen per-file model.
}
