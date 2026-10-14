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
pub const Container = struct {
    file: Project.FileId,
    scope: u32,
    symbolic: bool = false,
    /// For a container a type function made: the call that made it, whose arguments its
    /// methods' results may name. Identity is `file` and `scope` alone.
    made_by: ?*const Made = null,
};
pub const Made = struct { function: Decl, file: Project.FileId, call: Ast.Node.Index };
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
    /// An array of the element: `[N]T`. A slice or many-item pointer is a `pointer` to its
    /// element, as Zig indexes both the same way.
    array: *const Value,
    optional: *const Value,
    error_union: *const Value,
    error_set,
    scalar,
    /// One of several, each known: a `switch` or `if` whose branches differ, such as a type
    /// chosen per target. Never holds an unknown or another `alternatives`.
    alternatives: []const Value,

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
        .pointer, .array, .optional, .error_union => |inner| current = inner.*,
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
            return self.map(lhs, name, memberValue);
        },
        .optional_type => return .{ .optional = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        // A payload seen through what wraps it: `x catch ...` and `x orelse ...` have the
        // payload's type (Zig requires the other side to coerce to it), as `x.?` has.
        .@"catch" => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_node[0]), .error_union),
        .@"orelse" => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_node[0]), .optional),
        .unwrap_optional => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_token[0]), .optional),
        .@"switch", .switch_comma, .@"if" => if (try self.branches(file, node)) |value| return value,
        .grouped_expression => return self.resolve(file, tree.nodeData(node).node_and_token[0]),
        // Operators no aegis type takes: Zig has no operator overloading, and every aegis value
        // is a struct or an enum. Their results are numbers or booleans.
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .bool_and, .bool_or, .bool_not, .negation, .negation_wrap, .bit_not, .mul, .mul_wrap, .mul_sat, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor => return .scalar,
        // `+` and `-` also move many-item pointers: a number only from a number.
        .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat => {
            const lhs = try self.resolve(file, tree.nodeData(node).node_and_node[0]);
            return if (lhs == .scalar or lhs == .primitive) .scalar else .{ .unknown = .unsupported };
        },
        .error_union => return .{ .error_union = try self.boxed(try self.resolve(file, tree.nodeData(node).node_and_node[1])) },
        // An element of an array, a pointer to one, a slice or a many-item pointer.
        .array_access => return self.indexed(try self.resolve(file, tree.nodeData(node).node_and_node[0]), {}),
        // A slice of an array is a pointer to the elements (a pointer to an array when the bounds
        // are known, a slice when not: indexed alike); a slice of a slice or pointer is the same.
        .slice_open, .slice, .slice_sentinel => return self.sliced(try self.resolve(file, tree.fullSlice(node).?.ast.sliced), {}),
        // `++` joins arrays: the left side's kind, a string for a literal.
        .array_cat => {
            const lhs = try self.resolve(file, tree.nodeData(node).node_and_node[0]);
            return switch (lhs) {
                .scalar, .array, .unknown => lhs,
                else => .{ .unknown = .unsupported },
            };
        },
        .error_set_decl, .merge_error_sets => return .error_set,
        .enum_literal => return .{ .unknown = .comptime_dependent },
        .number_literal, .string_literal, .char_literal => return .scalar,
        else => {},
    }
    if (tree.fullPtrType(node)) |ptr| return .{ .pointer = try self.boxed(try self.resolve(file, ptr.ast.child_type)) };
    if (tree.fullArrayType(node)) |array| return .{ .array = try self.boxed(try self.resolve(file, array.ast.elem_type)) };
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
            if (std.mem.eql(u8, name, "@as") and args.len == 2) return self.instance(try self.resolve(file, args[0]));
            return .{ .unknown = .comptime_dependent };
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node).?;
            const callee = try self.resolve(file, call.ast.fn_expr);
            if (callee == .alternatives) return self.map(callee, {}, callResult);
            if (callee == .function) {
                if (try self.typeArgument(file, call, callee.function)) |result| return result;
                if (try self.madeResult(file, call, callee.function)) |value| return value;
                var result = try self.callResult(callee, {});
                if (result == .container and result.container.symbolic) {
                    const made = try self.gpa.create(Made);
                    made.* = .{ .function = callee.function, .file = file, .call = node };
                    result.container.made_by = made;
                }
                return result;
            }
            return self.callResult(callee, {});
        },
        .struct_init_one, .struct_init_one_comma, .struct_init, .struct_init_comma => {
            const value = tree.fullStructInit(&buffer, node).?;
            if (value.ast.type_expr.unwrap()) |t| return self.instance(try self.resolve(file, t));
            return .{ .unknown = .unsupported };
        },
        .address_of => return .{ .pointer = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        .deref => return self.pointee(try self.resolve(file, tree.nodeData(node).node), {}),
        .@"try" => return self.payload(try self.resolve(file, tree.nodeData(node).node), .error_union),
        else => return .{ .unknown = .unsupported },
    }
}

fn memberValue(self: *Facts, lhs: Value, name: []const u8) ResolveError!Value {
    const container = switch (lhs) {
        .container, .instance => |c| c,
        .pointer => |p| switch (p.*) {
            .instance, .container => |c| if (self.member(c, name)) |decl| return self.declaration(decl) else return sequence(lhs, name),
            .alternatives => return self.map(p.*, name, memberValue),
            else => return sequence(lhs, name),
        },
        .unknown => return lhs,
        else => return .{ .unknown = .unresolved },
    };
    if (self.member(container, name)) |decl| return self.declaration(decl);
    return .{ .unknown = .unresolved };
}

/// A pointer's `len` or `ptr` where what it points at has no such member: a slice's or an
/// array's length, a number, and its many-item pointer.
fn sequence(pointer: Value, name: []const u8) Value {
    if (std.mem.eql(u8, name, "len")) return .scalar;
    if (std.mem.eql(u8, name, "ptr")) return pointer;
    return .{ .unknown = .unsupported };
}

/// A call to a function whose result is written in terms of one of its own `comptime T: type`
/// parameters, such as `std.mem.zeroes(T)` or `gpa.create(T)`, returns that result with `T` the
/// type the call passes there. A call through a namespace or by name, or a method called on a
/// value, whose first parameter that value is.
fn typeArgument(self: *Facts, file: Project.FileId, call: Ast.full.Call, decl: Decl) ResolveError!?Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    // A method called on a value takes that value as its first parameter.
    var receiver: usize = 0;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        switch (try self.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
            .container => {},
            .instance => receiver = 1,
            .pointer => |p| if (p.* == .instance) {
                receiver = 1;
            } else return null,
            else => return null,
        }
    } else if (tree.nodeTag(call.ast.fn_expr) != .identifier) return null;
    const model = &self.project.models[decl.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, model.declarations[decl.index].node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    const generic: Generic = .{ .file = file, .call = call, .decl = decl, .function = function, .receiver = receiver };
    const result = (try self.written(generic, result_node, 0)) orelse return null;
    // `!T`: an error union whose error set the body infers.
    if (target_tree.tokenTag(target_tree.firstToken(result_node) - 1) == .bang) return .{ .error_union = try self.boxed(result) };
    return result;
}

/// A generic function called: where, how and what it declares.
const Generic = struct { file: Project.FileId, call: Ast.full.Call, decl: Decl, function: Ast.full.FnProto, receiver: usize };

/// A result type written in terms of a `comptime T: type` parameter (`T`, `*T`, `?T`, `[]T`,
/// `[N]T`, `E!*T`), with the call's argument for `T`; null for any other result.
fn written(self: *Facts, generic: Generic, node: Ast.Node.Index, depth: usize) ResolveError!?Value {
    if (depth == 16) return null;
    const model = &self.project.models[generic.decl.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const target_tree = &self.project.files[generic.decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (target_tree.fullPtrType(node)) |ptr| {
        const child = (try self.written(generic, ptr.ast.child_type, depth + 1)) orelse return null;
        return .{ .pointer = try self.boxed(child) };
    }
    if (target_tree.fullArrayType(node)) |array| {
        const child = (try self.written(generic, array.ast.elem_type, depth + 1)) orelse return null;
        return .{ .array = try self.boxed(child) };
    }
    switch (target_tree.nodeTag(node)) {
        .optional_type => {
            const child = (try self.written(generic, target_tree.nodeData(node).node, depth + 1)) orelse return null;
            return .{ .optional = try self.boxed(child) };
        },
        .error_union => {
            const child = (try self.written(generic, target_tree.nodeData(node).node_and_node[1], depth + 1)) orelse return null;
            return .{ .error_union = try self.boxed(child) };
        },
        .identifier => {},
        else => return null,
    }
    const ref = model.reference(node) orelse return null;
    const index = ref.declaration orelse return null;
    const parameter = model.declarations[index];
    if (parameter.kind != .parameter) return null;
    var it = generic.function.iterate(target_tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token != parameter.token) continue;
        const comptime_token = param.comptime_noalias orelse return null;
        if (target_tree.tokenTag(comptime_token) != .keyword_comptime) return null;
        const type_expr = param.type_expr orelse return null;
        if (target_tree.nodeTag(type_expr) != .identifier or !std.mem.eql(u8, target_tree.tokenSlice(target_tree.nodeMainToken(type_expr)), "type")) return null;
        if (position < generic.receiver or position - generic.receiver >= generic.call.ast.params.len) return null;
        return try self.instance(try self.resolve(generic.file, generic.call.ast.params[position - generic.receiver]));
    }
    return null;
}

/// A method of a container a type function made, called on a value of it: its declared result
/// with the type function's parameters read as the arguments of the call that made it, as
/// `Inbox(Message).takeAll` returning `?*T` returns `?*Message`.
fn madeResult(self: *Facts, file: Project.FileId, call: Ast.full.Call, decl: Decl) ResolveError!?Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver = try self.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
    const container = switch (receiver) {
        .instance => |c| c,
        .pointer => |p| switch (p.*) {
            .instance, .container => |c| c,
            else => return null,
        },
        else => return null,
    };
    const made = container.made_by orelse return null;
    const record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
    if (!decl.file.eql(container.file) or record.scope != container.scope) return null;
    const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, record.node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    var result = try self.substituted(decl.file, result_node, made, 0);
    if (result == .unknown) return null;
    // A container declared inside the made one, such as its guard, is made by the same call.
    if (result == .container and self.within(result.container, container)) result.container.made_by = made;
    if (target_tree.tokenTag(target_tree.firstToken(result_node) - 1) == .bang) return .{ .error_union = try self.boxed(try self.instance(result)) };
    return try self.instance(result);
}

fn within(self: *const Facts, inner: Container, outer: Container) bool {
    if (!inner.file.eql(outer.file)) return false;
    const scopes = self.project.models[inner.file.raw()].scopes; // safe: enum identities index their owning frozen tables without narrowing.
    var scope: ?u32 = scopes[inner.scope].parent;
    while (scope) |s| : (scope = scopes[s].parent) if (s == outer.scope) return true;
    return false;
}

/// A type expression written inside a type function's container, its parameters read as the
/// arguments of the call that made it.
fn substituted(self: *Facts, file: Project.FileId, node: Ast.Node.Index, made: *const Made, depth: usize) ResolveError!Value {
    if (depth == 16) return .{ .unknown = .budget };
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (tree.fullPtrType(node)) |ptr| {
        const child = try self.substituted(file, ptr.ast.child_type, made, depth + 1);
        if (child == .unknown) return child;
        return .{ .pointer = try self.boxed(child) };
    }
    if (tree.fullArrayType(node)) |array| {
        const child = try self.substituted(file, array.ast.elem_type, made, depth + 1);
        if (child == .unknown) return child;
        return .{ .array = try self.boxed(child) };
    }
    switch (tree.nodeTag(node)) {
        .optional_type => {
            const child = try self.substituted(file, tree.nodeData(node).node, made, depth + 1);
            if (child == .unknown) return child;
            return .{ .optional = try self.boxed(child) };
        },
        .identifier => if (try self.argumentFor(file, node, made)) |argument| return argument,
        else => {},
    }
    return self.resolve(file, node);
}

/// The argument the call `made` passed for the parameter `node` names, when it names one of
/// the type function's parameters.
fn argumentFor(self: *Facts, file: Project.FileId, node: Ast.Node.Index, made: *const Made) ResolveError!?Value {
    if (!file.eql(made.function.file)) return null;
    const model = &self.project.models[file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const ref = model.reference(node) orelse return null;
    const index = ref.declaration orelse return null;
    const parameter = model.declarations[index];
    if (parameter.kind != .parameter) return null;
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = tree.fullFnProto(&fn_buffer, model.declarations[made.function.index].node) orelse return null;
    var it = function.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token != parameter.token) continue;
        const call_tree = &self.project.files[made.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = call_tree.fullCall(&call_buffer, made.call) orelse return null;
        if (position >= call.ast.params.len) return null;
        return try self.resolve(made.file, call.ast.params[position]);
    }
    return null;
}

/// What calling `callee` returns: its declared result, or the container a type function makes.
fn callResult(self: *Facts, callee: Value, _: void) ResolveError!Value {
    if (callee == .function) {
        const decl = callee.function;
        const declaration_record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
        const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
        var fn_buffer: [1]Ast.Node.Index = undefined;
        const function = target_tree.fullFnProto(&fn_buffer, declaration_record.node).?;
        const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
        // `!T`: an error union whose error set the body infers.
        if (target_tree.tokenTag(target_tree.firstToken(result_node) - 1) == .bang) {
            const payload_value = try self.resolve(decl.file, result_node);
            if (payload_value == .unknown) return payload_value;
            return .{ .error_union = try self.boxed(try self.instance(payload_value)) };
        }
        const result = try self.resolve(decl.file, result_node);
        if (result == .primitive and std.mem.eql(u8, result.primitive, "type")) {
            var value = try self.template(decl) orelse return .{ .unknown = .comptime_dependent };
            if (value == .container) value.container.symbolic = function.ast.params.len != 0;
            return value;
        }
        return self.instance(result);
    }
    return .{ .unknown = .unresolved };
}

/// The payload of an optional or error union `value` is.
fn payload(self: *Facts, value: Value, wrapper: std.meta.Tag(Value)) ResolveError!Value {
    return switch (value) {
        .optional => |inner| if (wrapper == .optional) inner.* else .{ .unknown = .unsupported },
        .error_union => |inner| if (wrapper == .error_union) inner.* else .{ .unknown = .unsupported },
        .alternatives => self.map(value, wrapper, payload),
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

fn pointee(self: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .pointer => |inner| inner.*,
        .alternatives => self.map(value, {}, pointee),
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

/// An element of `value`: of an array, a pointer to an array, a slice or a many-item pointer.
fn indexed(self: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .array => |inner| inner.*,
        .pointer => |inner| switch (inner.*) {
            .array => |elements| elements.*,
            else => inner.*,
        },
        .alternatives => self.map(value, {}, indexed),
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

/// A slice of `value`: a pointer to an array's elements, or the slice or pointer itself.
fn sliced(self: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .array => .{ .pointer = try self.boxed(value) },
        .pointer, .unknown => value,
        .alternatives => self.map(value, {}, sliced),
        else => .{ .unknown = .unsupported },
    };
}

/// A `switch` or `if`-`else` expression: what its branches give, chosen as one. A branch
/// that gives no value of its own (`@compileError`, `unreachable`, `undefined`) is left out.
fn branches(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var values: std.ArrayList(Value) = .empty;
    if (tree.fullSwitch(node)) |whole| {
        for (whole.ast.cases) |case| {
            const branch = tree.fullSwitchCase(case).?.ast.target_expr;
            if (never(tree, branch)) continue;
            try values.append(self.gpa, try self.resolve(file, branch));
        }
    } else if (tree.fullIf(node)) |whole| {
        const otherwise = whole.ast.else_expr.unwrap() orelse return null;
        for ([_]Ast.Node.Index{ whole.ast.then_expr, otherwise }) |branch| {
            if (never(tree, branch)) continue;
            try values.append(self.gpa, try self.resolve(file, branch));
        }
    } else return null;
    return try self.choose(values.items);
}

fn never(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .unreachable_literal => true,
        // `undefined` takes the type of the other branches.
        .identifier => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined"),
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@compileError"),
        else => false,
    };
}

/// What a capture binds, where its source resolves: an `if` or `while` payload is its
/// condition's optional or error-union payload and its error capture an error; a `catch`
/// capture is an error; a switch prong's payload is the field of the subject's union that
/// every item of the prong names, or the subject itself when it is no union; a `for` capture
/// is its input's element, or a number for a range. A `|*x|` capture points at it. Anything
/// else stays unknown: an `else` prong of a union, a prong's tag capture, an input that is not
/// a slice.
fn captured(self: *Facts, decl: Decl) ResolveError!Value {
    const record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const node = record.node;
    const name = record.token;
    const by_pointer = tree.tokenTag(name - 1) == .asterisk;
    const bound: Value = if (tree.fullIf(node)) |branch|
        try self.conditional(decl.file, branch.payload_token, branch.error_token, branch.ast.cond_expr, name)
    else if (tree.fullWhile(node)) |loop|
        try self.conditional(decl.file, loop.payload_token, loop.error_token, loop.ast.cond_expr, name)
    else if (tree.nodeTag(node) == .@"catch")
        .error_set
    else if (tree.fullSwitchCase(node)) |case|
        try self.switchPayload(decl.file, node, case, name)
    else if (tree.fullFor(node)) |loop|
        try self.element(decl.file, loop, name)
    else
        .{ .unknown = .unsupported };
    if (bound == .unknown or !by_pointer) return bound;
    return .{ .pointer = try self.boxed(bound) };
}

fn conditional(self: *Facts, file: Project.FileId, payload_token: ?Ast.TokenIndex, error_token: ?Ast.TokenIndex, condition: Ast.Node.Index, name: Ast.TokenIndex) ResolveError!Value {
    if (error_token) |token| if (token == name) return .error_set;
    const first = payload_token orelse return .{ .unknown = .unsupported };
    if (first != name and first + 1 != name) return .{ .unknown = .unsupported };
    const value = try self.resolve(file, condition);
    return switch (value) {
        .optional, .error_union => |inner| inner.*,
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

fn switchPayload(self: *Facts, file: Project.FileId, case_node: Ast.Node.Index, full: Ast.full.SwitchCase, name: Ast.TokenIndex) ResolveError!Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    // The payload is the first capture; a second is the prong's tag.
    const first = full.payload_token orelse return .{ .unknown = .unsupported };
    if (first != name and first + 1 != name) return .{ .unknown = .unsupported };
    const parent = self.project.models[file.raw()].node_parents[@backingInt(case_node)] orelse return .{ .unknown = .unsupported }; // safe: enum identities index their owning frozen tables without narrowing.
    const whole = tree.fullSwitch(parent) orelse return .{ .unknown = .unsupported };
    const subject = try self.resolve(file, whole.ast.condition);
    // A pointer's target resolves as its type: a dereferenced subject is a container here.
    const container = switch (subject) {
        .instance, .container => |c| c,
        .unknown => return subject,
        // A number, a boolean or an error: the capture is the subject's value.
        .scalar, .primitive, .error_set => return subject,
        else => return .{ .unknown = .unsupported },
    };
    if (!self.isUnion(container)) return .{ .instance = container };
    if (full.ast.values.len == 0) return .{ .unknown = .unsupported };
    var found: ?Value = null;
    for (full.ast.values) |item| {
        if (tree.nodeTag(item) != .enum_literal) return .{ .unknown = .unsupported };
        const field_name = try self.memberName(tree.tokenSlice(tree.nodeMainToken(item)));
        const field = self.member(container, field_name) orelse return .{ .unknown = .unresolved };
        if (self.project.models[field.file.raw()].declarations[field.index].kind != .field) return .{ .unknown = .unsupported }; // safe: enum identities index their owning frozen tables without narrowing.
        const value = try self.declaration(field);
        if (value == .unknown) return value;
        if (found) |earlier| {
            if (!same(earlier, value, 0)) return .{ .unknown = .unsupported };
        } else found = value;
    }
    return found.?;
}

fn element(self: *Facts, file: Project.FileId, loop: Ast.full.For, name: Ast.TokenIndex) ResolveError!Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var position: usize = 0;
    var token = loop.payload_token;
    while (tree.tokenTag(token) != .pipe) : (token += 1) {
        if (tree.tokenTag(token) != .identifier) continue;
        if (token == name) break;
        position += 1;
    } else return .{ .unknown = .unsupported };
    if (position >= loop.ast.inputs.len) return .{ .unknown = .unsupported };
    const input = loop.ast.inputs[position];
    if (tree.nodeTag(input) == .for_range) return .scalar;
    // A `for` takes arrays, pointers to arrays and slices, never a single item: a resolved
    // pointer input is a slice, whose element is what it points at.
    return self.indexed(try self.resolve(file, input), {});
}

fn isUnion(self: *const Facts, container: Container) bool {
    const model = &self.project.models[container.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[container.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const scope = model.scopes[container.scope];
    if (scope.kind != .container) return false;
    return tree.tokenTag(tree.nodeMainToken(scope.node)) == .keyword_union;
}

fn same(a: Value, b: Value, depth: usize) bool {
    if (depth == 64) return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .pointer, .array, .optional, .error_union => |inner| same(inner.*, switch (b) {
            .pointer, .array, .optional, .error_union => |other| other.*,
            else => unreachable,
        }, depth + 1),
        .container, .instance => |c| blk: {
            const other = switch (b) {
                .container, .instance => |o| o,
                else => unreachable,
            };
            break :blk c.file.eql(other.file) and c.scope == other.scope;
        },
        .primitive => |p| std.mem.eql(u8, p, b.primitive),
        .function => |f| std.meta.eql(f, b.function),
        .alternatives => |each| each.len == b.alternatives.len and for (each, b.alternatives) |x, y| {
            if (!same(x, y, depth + 1)) break false;
        } else true,
        .unknown => false,
        .error_set, .scalar => true,
    };
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
        return self.instance(value);
    }
    if (declaration_record.kind == .capture) return self.captured(decl);
    if (declaration_record.kind == .field) {
        const field = tree.fullContainerField(declaration_record.node).?;
        if (field.ast.type_expr.unwrap()) |t| return self.instance(try self.resolve(decl.file, t));
        return .{ .unknown = .unsupported };
    }
    if (tree.fullVarDecl(declaration_record.node)) |variable| {
        if (variable.ast.type_node.unwrap()) |t| {
            const type_value = try self.resolve(decl.file, t);
            if (type_value != .primitive or !std.mem.eql(u8, type_value.primitive, "type")) return self.instance(type_value);
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

fn instance(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .container => |c| .{ .instance = c },
        .alternatives => |each| blk: {
            const mapped = try self.gpa.alloc(Value, each.len);
            for (each, mapped) |one, *out| out.* = try self.instance(one);
            break :blk .{ .alternatives = mapped };
        },
        else => value,
    };
}

/// One value of `values`, each resolved: an unknown if any is, the value if they agree, else
/// the alternatives.
fn choose(self: *Facts, values: []const Value) ResolveError!Value {
    var kept: std.ArrayList(Value) = .empty;
    for (values) |value| {
        if (value == .unknown) return value;
        const parts: []const Value = if (value == .alternatives) value.alternatives else &.{value};
        for (parts) |part| {
            for (kept.items) |earlier| {
                if (same(earlier, part, 0)) break;
            } else try kept.append(self.gpa, part);
        }
    }
    if (kept.items.len == 0) return .{ .unknown = .unsupported };
    if (kept.items.len == 1) return kept.items[0];
    return .{ .alternatives = kept.items };
}

/// `f(value)` for each alternative of `value`, chosen as one.
fn map(self: *Facts, value: Value, context: anytype, comptime f: fn (*Facts, Value, @TypeOf(context)) ResolveError!Value) ResolveError!Value {
    if (value != .alternatives) return f(self, value, context);
    const mapped = try self.gpa.alloc(Value, value.alternatives.len);
    for (value.alternatives, mapped) |one, *out| out.* = try f(self, one, context);
    return self.choose(mapped);
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
