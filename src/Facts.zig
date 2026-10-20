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
/// What each generic parameter binds when the project's own calls are the only ones: the
/// union of their arguments, or null when the function is reachable from outside or taken
/// other than by a call.
callers: std.AutoHashMapUnmanaged(Decl, ?Value) = .empty,
/// The containers a package's consumers reach by name through public declarations from its
/// module roots, found once.
exported: ?std.AutoHashMapUnmanaged(Container, void) = null,
/// The names some container in the project declares as `comptime` fields, found once.
comptime_fields: ?std.StringHashMapUnmanaged(void) = null,
/// The declarations the program dereferences (`p.*`), found per file once.
dereferences: std.AutoHashMapUnmanaged(Decl, void) = .empty,
dereferences_found: std.AutoHashMapUnmanaged(Project.FileId, void) = .empty,
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
pub const Made = struct { function: Decl, file: Project.FileId, call: Ast.Node.Index, env: ?*const Env = null };
/// One call of a generic function being read: its parameters bound to the call's arguments,
/// in order (a method's receiver first). A type it returns, or a result type written in terms
/// of them, is read with these bindings.
pub const Env = struct { function: Decl, args: []const Value, depth: usize };
/// A type seen through `@typeInfo`, and how far into its information a chain of fields has
/// gone: `.pointer.child`, `.optional.child`, `.array.child`, `.error_union.payload`,
/// `.@"fn".return_type` and `.@"fn".param_types[i]`. `part` is any other part of the
/// information (`.@"struct".fields`, a field's `name`): a `std.builtin.Type` value whose own
/// members are not followed. A type that does not resolve still has information: what it
/// describes stays unknown, never what the information is.
pub const Reflected = struct { of: *const Value, at: enum { info, pointer, optional, array, error_union, function, params, part } };
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
/// Why a value is unknown. `absent`: it comes from a module the build does not have for this
/// file (Project.Input.absent), so the code that needs it is not compiled in this build.
pub const Unknown = enum { invalid_front_end, unresolved, missing_mapping, computed_import, comptime_dependent, cycle, budget, unsupported, absent };
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
    reflected: Reflected,
    /// A struct literal with no type of its own where nothing gives it one (`.{ .a = x }` as a
    /// block's value or an `anytype` argument): an anonymous struct whose fields are the ones
    /// the literal names, with the values it gives them.
    literal: Key,

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
    self.callers.deinit(self.gpa);
    if (self.exported) |*set| set.deinit(self.gpa);
    if (self.comptime_fields) |*names| names.deinit(self.gpa);
    self.dereferences.deinit(self.gpa);
    self.dereferences_found.deinit(self.gpa);
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
            // A member of a type function's container, as `Budget.Reservation` names the
            // reservation every budget declares.
            .function => |function| switch ((try self.template(function)) orelse return .{ .gap = .unsupported }) {
                .container, .instance => |c| c,
                else => return .{ .gap = .unsupported },
            },
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
            // A literal no aegis type is: `null`, and the booleans.
            if (tag == .identifier) for ([_][]const u8{ "null", "true", "false" }) |literal| {
                if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), literal)) return .scalar;
            };
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
            return self.memberValue(lhs, name);
        },
        .optional_type => return .{ .optional = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        // A payload seen through what wraps it: `x catch ...` and `x orelse ...` have the
        // payload's type (Zig requires the other side to coerce to it), as `x.?` has.
        .@"catch" => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_node[0]), .error_union),
        .@"orelse" => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_node[0]), .optional),
        .unwrap_optional => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_token[0]), .optional),
        .@"switch", .switch_comma, .@"if" => if (try self.branches(null, file, node)) |value| return value,
        .block, .block_semicolon, .block_two, .block_two_semicolon => if (try self.breaks(file, node)) |value| return value,
        .for_simple, .@"for", .while_simple, .while_cont, .@"while" => if (try self.loopValue(file, node)) |value| return value,
        .grouped_expression => return self.resolve(file, tree.nodeData(node).node_and_token[0]),
        // `comptime x` and `nosuspend x` have `x`'s type.
        .@"comptime", .@"nosuspend" => return self.resolve(file, tree.nodeData(node).node),
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
        .array_access => {
            const operands = tree.nodeData(node).node_and_node;
            const base = try self.resolve(file, operands[0]);
            return self.elementOf(base, tree, operands[1]);
        },
        // A slice of an array is a pointer to the elements (a pointer to an array when the bounds
        // are known, a slice when not: indexed alike); a slice of a slice or pointer is the same.
        .slice_open, .slice, .slice_sentinel => return self.sliced(try self.resolve(file, tree.fullSlice(node).?.ast.sliced), {}),
        // `++` joins arrays: the left side's kind, a string for a literal, and an array of the
        // elements for slices and pointers to arrays, whose lengths are known at compile time.
        .array_cat => {
            const lhs = try self.resolve(file, tree.nodeData(node).node_and_node[0]);
            return switch (lhs) {
                .scalar, .array, .unknown => lhs,
                .pointer => |to| switch (to.*) {
                    .array => to.*,
                    .unknown => to.*,
                    else => .{ .array = to },
                },
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
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return self.builtin(file, node),
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node).?;
            const callee = try self.resolve(file, call.ast.fn_expr);
            if (callee == .alternatives) return self.map(callee, {}, callResult);
            if (callee == .function) {
                if (try self.typeArgument(file, call, callee.function)) |result| return result;
                if (try self.madeResult(file, call, callee.function)) |value| return value;
                if (try self.evaluateCall(null, file, call, callee.function)) |value| return value;
                var result = try self.callResult(callee, {});
                if (result == .container and result.container.symbolic) {
                    const made = try self.gpa.create(Made);
                    made.* = .{ .function = callee.function, .file = file, .call = node };
                    result.container.made_by = made;
                }
                return result;
            }
            if (try self.throughPointer(file, call.ast.fn_expr)) |value| return value;
            return self.callResult(callee, {});
        },
        .struct_init_one, .struct_init_one_comma, .struct_init, .struct_init_comma, .struct_init_dot, .struct_init_dot_comma, .struct_init_dot_two, .struct_init_dot_two_comma => {
            const value = tree.fullStructInit(&buffer, node).?;
            if (value.ast.type_expr.unwrap()) |t| return self.instance(try self.resolve(file, t));
            return .{ .literal = .{ .file = file, .node = node } };
        },
        .array_init_one, .array_init_one_comma, .array_init, .array_init_comma => {
            const value = tree.fullArrayInit(&buffer, node).?;
            if (value.ast.type_expr.unwrap()) |t| return self.instance(try self.resolve(file, t));
            return .{ .unknown = .unsupported };
        },
        .address_of => return .{ .pointer = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        .deref => return self.pointee(try self.resolve(file, tree.nodeData(node).node), {}),
        .@"try" => return self.payload(try self.resolve(file, tree.nodeData(node).node), .error_union),
        else => return .{ .unknown = .unsupported },
    }
}

/// What a builtin call gives: an imported file, `@This()`, a reflected declaration, a type
/// `@as` names, a value's type, a type's information.
fn builtin(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const model = &self.project.models[file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    var buffer: [2]Ast.Node.Index = undefined;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const args = builtinArgs(tree, node, &buffer);
    if (std.mem.eql(u8, name, "@import")) {
        if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return .{ .unknown = .computed_import };
        const spelling = std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return .{ .unknown = .computed_import },
        };
        const target = self.project.imported(file, spelling) orelse return .{ .unknown = if (self.project.absent(file, spelling)) .absent else .missing_mapping };
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
    if (std.mem.eql(u8, name, "@TypeOf") and args.len == 1) return self.map(try self.resolve(file, args[0]), {}, typeOf);
    if (std.mem.eql(u8, name, "@typeInfo") and args.len == 1) return self.reflect(try self.resolve(file, args[0]));
    // A name's bytes: `[:0]const u8`, or the file's bytes for `@embedFile`.
    for ([_][]const u8{ "@errorName", "@tagName", "@typeName", "@embedFile" }) |bytes| if (std.mem.eql(u8, name, bytes)) return .{ .pointer = try self.boxed(.{ .primitive = "u8" }) };
    // A number or a truth value, whatever the arguments are.
    for (numeric_builtins) |number| if (std.mem.eql(u8, name, number)) return .scalar;
    return .{ .unknown = .comptime_dependent };
}

/// Builtins whose result is a number or a truth value: sizes and offsets, conversions to
/// integers, bit counts, arithmetic and the queries that answer yes or no.
const numeric_builtins = [_][]const u8{
    "@sizeOf",       "@alignOf",       "@bitSizeOf",    "@offsetOf",     "@bitOffsetOf", "@intFromPtr", "@intFromBool", "@intFromEnum",
    "@intFromError", "@intFromFloat",  "@clz",          "@ctz",          "@popCount",    "@byteSwap",   "@bitReverse",  "@divExact",
    "@divFloor",     "@divTrunc",      "@mod",          "@rem",          "@shlExact",    "@shrExact",   "@min",         "@max",
    "@abs",          "@sqrt",          "@floor",        "@ceil",         "@trunc",       "@round",      "@hasDecl",     "@hasField",
    "@inComptime",   "@returnAddress", "@frameAddress", "@floatFromInt", "@mulAdd",      "@sin",        "@cos",         "@exp",
};

fn memberValue(self: *Facts, lhs: Value, name: []const u8) ResolveError!Value {
    if (lhs == .reflected) return self.reflectedMember(lhs.reflected, name);
    if (lhs == .literal) return self.literalField(lhs.literal, name);
    if (lhs == .pointer and lhs.pointer.* == .literal) return self.literalField(lhs.pointer.literal, name);
    if (lhs == .pointer and lhs.pointer.* == .alternatives) return self.memberOfChoice(lhs.pointer.alternatives, name);
    if (lhs == .alternatives) return self.memberOfChoice(lhs.alternatives, name);
    const container = switch (lhs) {
        .container, .instance => |c| c,
        .pointer => |p| switch (p.*) {
            .instance, .container => |c| if (self.member(c, name)) |decl| return self.memberOf(c, decl) else return sequence(lhs, name),
            .alternatives => return self.map(p.*, name, memberValue),
            else => return sequence(lhs, name),
        },
        .unknown => return lhs,
        else => return .{ .unknown = .unresolved },
    };
    if (self.member(container, name)) |decl| return self.memberOf(container, decl);
    return .{ .unknown = .unresolved };
}

/// Whether a container written in the program declares no member `name`.
fn lacks(self: *const Facts, container: Container, name: []const u8) bool {
    return !container.symbolic and self.member(container, name) == null;
}

/// A field of an anonymous struct literal: the value the literal gives it.
fn literalField(self: *Facts, literal: Key, name: []const u8) ResolveError!Value {
    const tree = &self.project.files[literal.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var buffer: [2]Ast.Node.Index = undefined;
    const full = tree.fullStructInit(&buffer, literal.node) orelse return .{ .unknown = .unsupported };
    for (full.ast.fields) |field| {
        const label = try self.memberName(tree.tokenSlice(tree.firstToken(field) - 2));
        if (std.mem.eql(u8, label, name)) return self.resolve(literal.file, field);
    }
    return .{ .unknown = .unresolved };
}

/// A member of one of several types chosen at compile time: a choice without members (`void`,
/// a number) is a build in which this access does not compile, so it is left out.
fn memberOfChoice(self: *Facts, choices: []const Value, name: []const u8) ResolveError!Value {
    var kept: std.ArrayList(Value) = .empty;
    for (choices) |choice| switch (choice) {
        .primitive, .scalar => continue,
        // A type that declares no such member, likewise.
        .container, .instance => |c| if (self.lacks(c, name)) continue else try kept.append(self.gpa, try self.memberValue(choice, name)),
        .pointer => |to| switch (to.*) {
            .container, .instance => |c| if (self.lacks(c, name)) continue else try kept.append(self.gpa, try self.memberValue(choice, name)),
            else => try kept.append(self.gpa, try self.memberValue(choice, name)),
        },
        else => try kept.append(self.gpa, try self.memberValue(choice, name)),
    };
    if (kept.items.len == 0) return .{ .unknown = .unresolved };
    return self.choose(kept.items);
}

/// A member of `container`: a field of a container a type function made is of its declared
/// type with the function's parameters read as the call's arguments, and a container declared
/// inside the made one is made by the same call.
fn memberOf(self: *Facts, container: Container, decl: Decl) ResolveError!Value {
    const made = container.made_by orelse return self.declaration(decl);
    const record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
    // A type it declares (`Replay`, `Record`) is made by the same call.
    if (record.kind != .field) return self.madeWithin(try self.declaration(decl), container, made);
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const field = tree.fullContainerField(record.node) orelse return self.declaration(decl);
    const type_node = field.ast.type_expr.unwrap() orelse return self.declaration(decl);
    const value = try self.substituted(decl.file, type_node, made);
    if (value == .unknown) return self.declaration(decl);
    return self.valueOf(try self.madeWithin(value, container, made));
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
    var result = try self.substituted(decl.file, result_node, made);
    if (result == .unknown) return null;
    result = try self.madeWithin(result, container, made);
    if (target_tree.tokenTag(target_tree.firstToken(result_node) - 1) == .bang) return .{ .error_union = try self.boxed(try self.instance(result)) };
    return try self.instance(result);
}

/// `value` with every container declared inside `outer` (a made container's guard, its
/// record type), also behind pointers, optionals, error unions and arrays, made by the same
/// call as `outer`.
fn madeWithin(self: *Facts, value: Value, outer: Container, made: *const Made) ResolveError!Value {
    return switch (value) {
        .container => |inner| if (self.within(inner, outer)) .{ .container = .{ .file = inner.file, .scope = inner.scope, .symbolic = inner.symbolic, .made_by = made } } else value,
        .instance => |inner| if (self.within(inner, outer)) .{ .instance = .{ .file = inner.file, .scope = inner.scope, .symbolic = inner.symbolic, .made_by = made } } else value,
        .pointer => |to| .{ .pointer = try self.boxed(try self.madeWithin(to.*, outer, made)) },
        .optional => |to| .{ .optional = try self.boxed(try self.madeWithin(to.*, outer, made)) },
        .error_union => |to| .{ .error_union = try self.boxed(try self.madeWithin(to.*, outer, made)) },
        .array => |to| .{ .array = try self.boxed(try self.madeWithin(to.*, outer, made)) },
        else => value,
    };
}

fn within(self: *const Facts, inner: Container, outer: Container) bool {
    if (!inner.file.eql(outer.file)) return false;
    const scopes = self.project.models[inner.file.raw()].scopes; // safe: enum identities index their owning frozen tables without narrowing.
    var scope: ?u32 = scopes[inner.scope].parent;
    while (scope) |s| : (scope = scopes[s].parent) if (s == outer.scope) return true;
    return false;
}

/// A type expression written inside a type function's container, its parameters read as the
/// arguments of the call that made it: the same reading as a generic call's (`resolveIn`).
fn substituted(self: *Facts, file: Project.FileId, node: Ast.Node.Index, made: *const Made) ResolveError!Value {
    return self.resolveIn(try self.madeEnv(made), file, node);
}

/// The bindings of the call that made a container: the type function's parameters bound to its
/// arguments (read with the bindings of the reading that made it, if any). A parameter the
/// function passes on changed when it calls itself again is not the call's argument on that
/// path, so it stays unknown.
fn madeEnv(self: *Facts, made: *const Made) ResolveError!*const Env {
    const call_tree = &self.project.files[made.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = call_tree.fullCall(&call_buffer, made.call).?;
    const args = try self.gpa.alloc(Value, call.ast.params.len);
    for (call.ast.params, args, 0..) |param, *arg, position| {
        arg.* = if (try self.passedOnChanged(made.function, position))
            .{ .unknown = .comptime_dependent }
        else if (made.env) |env| try self.resolveIn(env, made.file, param) else try self.resolve(made.file, param);
    }
    const env = try self.gpa.create(Env);
    env.* = .{ .function = made.function, .args = args, .depth = if (made.env) |e| e.depth + 1 else 0 };
    return env;
}

fn passedOnChanged(self: *const Facts, function: Decl, position: usize) ResolveError!bool {
    const tree = &self.project.files[function.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const fn_node = self.scopeNode(function);
    if (tree.nodeTag(fn_node) != .fn_decl) return false;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return false;
    if (statements.len == 0) return false;
    const changed = self.recursion(function, body, statements[statements.len - 1]) orelse return false;
    return position < 64 and changed & (@as(u64, 1) << @intCast(position)) != 0; // safe: bounded by the check before it.
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
        // A choice that is not so wrapped (`void` off Linux) is a build in which this unwrap
        // does not compile: it is left out.
        .alternatives => |each| blk: {
            var kept: std.ArrayList(Value) = .empty;
            for (each) |one| if (one == wrapper or one == .unknown) try kept.append(self.gpa, try self.payload(one, wrapper));
            if (kept.items.len == 0) break :blk .{ .unknown = .unsupported };
            break :blk self.choose(kept.items);
        },
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
        // A string literal's bytes stay plain bytes.
        .pointer, .unknown, .scalar => value,
        .alternatives => self.map(value, {}, sliced),
        else => .{ .unknown = .unsupported },
    };
}

/// A `switch` or `if`-`else` expression: what its branches give, chosen as one. A branch
/// that gives no value of its own (`@compileError`, `unreachable`, `undefined`) or never
/// completes (`return`, `break`, `continue`, `@panic`, `@trap`) is left out; a `null` one
/// makes the others optional.
fn branches(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var values: std.ArrayList(Value) = .empty;
    var nullable = false;
    if (tree.fullSwitch(node)) |whole| {
        for (whole.ast.cases) |case| {
            const branch = tree.fullSwitchCase(case).?.ast.target_expr;
            if (never(tree, branch)) continue;
            if (isNull(tree, branch)) {
                nullable = true;
                continue;
            }
            try values.append(self.gpa, try self.resolveIn(env, file, branch));
        }
    } else if (tree.fullIf(node)) |whole| {
        const otherwise = whole.ast.else_expr.unwrap() orelse return null;
        for ([_]Ast.Node.Index{ whole.ast.then_expr, otherwise }) |branch| {
            if (never(tree, branch)) continue;
            if (isNull(tree, branch)) {
                nullable = true;
                continue;
            }
            try values.append(self.gpa, try self.resolveIn(env, file, branch));
        }
    } else return null;
    const chosen = try self.choose(values.items);
    if (!nullable or chosen == .unknown or chosen == .optional) return chosen;
    return .{ .optional = try self.boxed(chosen) };
}

/// A labeled block: what its `break`s give it, chosen as one, as a `switch`'s branches are.
fn breaks(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const brace = tree.nodeMainToken(node);
    if (brace < 2 or tree.tokenTag(brace - 1) != .colon or tree.tokenTag(brace - 2) != .identifier) return null;
    // Zig refuses a label that shadows another, so the name finds this block's breaks.
    const label = tree.tokenSlice(brace - 2);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var values: std.ArrayList(Value) = .empty;
    var nullable = false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        const at = tree.nodeMainToken(jump);
        if (at < first or at > last) continue;
        const data = tree.nodeData(jump).opt_token_and_opt_node;
        const token = data[0].unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token), label)) continue;
        const operand = data[1].unwrap() orelse return null;
        if (never(tree, operand)) continue;
        if (isNull(tree, operand)) {
            nullable = true;
            continue;
        }
        try values.append(self.gpa, try self.resolve(file, operand));
    }
    const chosen = try self.choose(values.items);
    if (!nullable or chosen == .unknown or chosen == .optional) return chosen;
    return .{ .optional = try self.boxed(chosen) };
}

/// A loop used as a value (`const e = for (xs) |x| { if (p(x)) break x; } else null;`): what
/// its own breaks give, chosen with its `else` branch as a `switch`'s branches are. A break
/// is the loop's own when it names the loop's label, or names none and no loop nested in this
/// one encloses it.
fn loopValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const parents = self.project.models[file.raw()].node_parents; // safe: enum identities index their owning frozen tables without narrowing.
    const body: Ast.Node.Index, const otherwise: Ast.Node.Index, const label: ?[]const u8 = if (tree.fullFor(node)) |loop|
        .{ loop.ast.then_expr, loop.ast.else_expr.unwrap() orelse return null, if (loop.label_token) |t| tree.tokenSlice(t) else null }
    else if (tree.fullWhile(node)) |loop|
        .{ loop.ast.then_expr, loop.ast.else_expr.unwrap() orelse return null, if (loop.label_token) |t| tree.tokenSlice(t) else null }
    else
        return null;
    var values: std.ArrayList(Value) = .empty;
    var nullable = false;
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        const at = tree.nodeMainToken(jump);
        if (at < first or at > last) continue;
        const data = tree.nodeData(jump).opt_token_and_opt_node;
        if (data[0].unwrap()) |token| {
            if (label == null or !std.mem.eql(u8, tree.tokenSlice(token), label.?)) continue;
        } else {
            // The innermost loop around the break, short of this one, takes it.
            var up = parents[@backingInt(jump)]; // safe: a node index indexes its own tree's parent table.
            const inner = while (up) |p| : (up = parents[@backingInt(p)]) { // safe: a node index indexes its own tree's parent table.
                if (p == node) break false;
                if (tree.fullFor(p) != null or tree.fullWhile(p) != null) break true;
            } else true;
            if (inner) continue;
        }
        const operand = data[1].unwrap() orelse return null;
        if (never(tree, operand)) continue;
        if (isNull(tree, operand)) {
            nullable = true;
            continue;
        }
        try values.append(self.gpa, try self.resolve(file, operand));
    }
    if (isNull(tree, otherwise)) nullable = true else if (!never(tree, otherwise)) try values.append(self.gpa, try self.resolve(file, otherwise));
    if (values.items.len == 0) return null;
    const chosen = try self.choose(values.items);
    if (!nullable or chosen == .unknown or chosen == .optional) return chosen;
    return .{ .optional = try self.boxed(chosen) };
}

/// A call through a field that holds a function pointer (`read: *const fn (...) R`): what
/// the pointer's function type returns.
fn throughPointer(self: *Facts, file: Project.FileId, callee: Ast.Node.Index) ResolveError!?Value {
    var decl = (try self.definition(file, callee)) orelse return null;
    var record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
    // A local holding the field, unwrapped: `const f = x.handler orelse return;`.
    if (record.kind == .variable) {
        const local = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
        var value = (local.fullVarDecl(record.node) orelse return null).ast.init_node.unwrap() orelse return null;
        while (true) value = switch (local.nodeTag(value)) {
            .@"orelse" => local.nodeData(value).node_and_node[0],
            .unwrap_optional, .grouped_expression => local.nodeData(value).node_and_token[0],
            else => break,
        };
        decl = (try self.definition(decl.file, value)) orelse return null;
        record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
    }
    if (record.kind != .field) return null;
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var declared = (tree.fullContainerField(record.node) orelse return null).ast.type_expr.unwrap() orelse return null;
    if (tree.nodeTag(declared) == .optional_type) declared = tree.nodeData(declared).node;
    if (tree.fullPtrType(declared)) |ptr| declared = ptr.ast.child_type;
    var buffer: [1]Ast.Node.Index = undefined;
    const signature = tree.fullFnProto(&buffer, declared) orelse return null;
    const result = signature.ast.return_type.unwrap() orelse return null;
    const value = try self.resolve(decl.file, result);
    if (value == .unknown) return null;
    return try self.valueOf(value);
}

fn isNull(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "null");
}

fn never(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .unreachable_literal, .@"return", .@"break", .@"continue" => true,
        // `undefined` takes the type of the other branches.
        .identifier => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "undefined"),
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => for ([_][]const u8{ "@compileError", "@panic", "@trap" }) |name| {
            if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name)) break true;
        } else false,
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
    // A switch on type information (`@typeInfo(T)`) captures the part its prong names.
    if (subject == .reflected and subject.reflected.at == .info) {
        if (full.ast.values.len != 1 or tree.nodeTag(full.ast.values[0]) != .enum_literal) return .{ .reflected = .{ .of = subject.reflected.of, .at = .part } };
        return self.reflectedMember(subject.reflected, try self.memberName(tree.tokenSlice(tree.nodeMainToken(full.ast.values[0]))));
    }
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
    // An `inline for` over a tuple written in place (`.{ a, b }`): each element in turn.
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, input)) |list| if (list.ast.type_expr == .none) {
        const each = try self.gpa.alloc(Value, list.ast.elements.len);
        for (list.ast.elements, each) |item, *out| out.* = try self.resolve(file, item);
        return self.choose(each);
    };
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
        .reflected => false,
        // One literal is one anonymous type; two literals are two.
        .literal => |l| std.meta.eql(l, b.literal),
    };
}

/// The container a type function returns when its body ends in one `return` of that container,
/// whatever comptime checks come before. This is the template, not an instantiation: no
/// arguments are evaluated.
pub fn template(self: *Facts, decl: Decl) ResolveError!?Value {
    if (self.templates.get(decl)) |known| return known;
    // A type function that returns another's call is read through it; one that reaches itself
    // again that way makes no container.
    try self.templates.put(self.gpa, decl, null);
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
    // Only the final statement may return something else: a `return` before it, in a check, a
    // branch or a nested block, gives this function's own container only by calling it again
    // (`Aligned(T, null)` for a list's natural alignment). Those after it are inside the
    // returned container, where only nested functions can contain one.
    _ = self.recursion(decl, body, last) orelse return null;
    const returned = tree.nodeData(last).opt_node.unwrap() orelse return null;
    var container_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_buffer, returned) == null) {
        // `return Owner(T, false, cleanup);`: the container another type function makes, the
        // same template whatever arguments this one passes it.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, returned) orelse return null;
        const callee = (try self.definition(decl.file, call.ast.fn_expr)) orelse return null;
        const function = (try self.origin(callee)) orelse return null;
        if (self.project.models[function.file.raw()].declarations[function.index].kind != .function) return null; // safe: a declaration identity indexes its own frozen model.
        return self.template(function);
    }
    const value = try self.resolve(decl.file, returned);
    return value;
}

pub fn declaration(self: *Facts, decl: Decl) ResolveError!Value {
    const model = &self.project.models[decl.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const declaration_record = model.declarations[decl.index];
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (declaration_record.kind == .function) return .{ .function = decl };
    if (declaration_record.kind == .parameter) {
        if (try self.settledByCalls(decl)) |position| return self.boundByCallers(decl, position);
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
        if (model.node_parents[@backingInt(declaration_record.node)]) |parent| if (tree.nodeTag(parent) == .assign_destructure) return self.destructured(decl.file, parent, declaration_record.node); // safe: a node index indexes its own tree's parent table.
    }
    return .{ .unknown = .unsupported };
}

/// The variable `variable` of `const a, const b = value;`: the field of a tuple at its
/// position, or an element of an array.
fn destructured(self: *Facts, file: Project.FileId, whole: Ast.Node.Index, variable: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const full = tree.assignDestructure(whole);
    const position = std.mem.findScalar(Ast.Node.Index, full.ast.variables, variable) orelse return .{ .unknown = .unsupported };
    const value = try self.resolve(file, full.ast.value_expr);
    switch (value) {
        .array => |each| return each.*,
        .instance => |tuple| {
            const model = &self.project.models[tuple.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
            const source = &self.project.files[tuple.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
            var buffer: [2]Ast.Node.Index = undefined;
            const container = source.fullContainerDecl(&buffer, model.scopes[tuple.scope].node) orelse return .{ .unknown = .unsupported };
            var at: usize = 0;
            for (container.ast.members) |item| {
                const field = source.fullContainerField(item) orelse continue;
                if (!field.ast.tuple_like) return .{ .unknown = .unsupported };
                if (at == position) return self.instance(try self.resolve(tuple.file, field.ast.type_expr.unwrap() orelse return .{ .unknown = .unsupported }));
                at += 1;
            }
            return .{ .unknown = .unsupported };
        },
        .unknown => return value,
        else => return .{ .unknown = .unsupported },
    }
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

/// A value of the type `value` names: an instance of a container, and through a pointer,
/// optional, error union or array type, the same wrapper around an instance of its payload
/// (`E!Self` gives an error union whose payload is a `Self`).
fn instance(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .container => |c| .{ .instance = c },
        .pointer => |inner| .{ .pointer = try self.boxed(try self.instance(inner.*)) },
        .optional => |inner| .{ .optional = try self.boxed(try self.instance(inner.*)) },
        .error_union => |inner| .{ .error_union = try self.boxed(try self.instance(inner.*)) },
        .array => |inner| .{ .array = try self.boxed(try self.instance(inner.*)) },
        // No value has type `noreturn`: a choice of types gives values of the others.
        .alternatives => |each| blk: {
            var mapped: std.ArrayList(Value) = .empty;
            for (each) |one| if (one != .primitive or !std.mem.eql(u8, one.primitive, "noreturn")) try mapped.append(self.gpa, try self.instance(one));
            if (mapped.items.len == 1) break :blk mapped.items[0];
            break :blk .{ .alternatives = mapped.items };
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

/// The type of a value: an instance is of its container; pointers, arrays, optionals and error
/// unions read the same as values and as types here, and a function is its own type.
fn typeOf(_: *Facts, value: Value, _: void) ResolveError!Value {
    return switch (value) {
        .instance => |c| .{ .container = c },
        else => value,
    };
}

fn reflect(self: *Facts, of: Value) ResolveError!Value {
    // Each of several types chosen at compile time is reflected on its own.
    if (of == .alternatives) {
        const each = try self.gpa.alloc(Value, of.alternatives.len);
        for (of.alternatives, each) |one, *out| out.* = .{ .reflected = .{ .of = try self.boxed(one), .at = .info } };
        return .{ .alternatives = each };
    }
    return .{ .reflected = .{ .of = try self.boxed(of), .at = .info } };
}

/// `base[index]`: a reflected function's parameter type, or an element.
fn elementOf(self: *Facts, base: Value, tree: *const Ast, index_node: Ast.Node.Index) ResolveError!Value {
    switch (base) {
        .reflected => |r| return self.reflectedElement(r, tree, index_node),
        .alternatives => |each| {
            const mapped = try self.gpa.alloc(Value, each.len);
            for (each, mapped) |one, *out| out.* = try self.elementOf(one, tree, index_node);
            return self.choose(mapped);
        },
        else => return self.indexed(base, {}),
    }
}

/// A field of reflected information: the kind of type it describes, then its parts.
fn reflectedMember(self: *Facts, r: Reflected, name: []const u8) ResolveError!Value {
    const unsupported: Value = .{ .unknown = .unsupported };
    switch (r.at) {
        .info => {
            const kinds = .{ .{ "pointer", .pointer }, .{ "optional", .optional }, .{ "array", .array }, .{ "error_union", .error_union }, .{ "fn", .function } };
            inline for (kinds) |kind| if (std.mem.eql(u8, name, kind[0])) return .{ .reflected = .{ .of = r.of, .at = kind[1] } };
            return .{ .reflected = .{ .of = r.of, .at = .part } };
        },
        .pointer => return if (std.mem.eql(u8, name, "child")) self.pointee(r.of.*, {}) else unsupported,
        .optional => return if (std.mem.eql(u8, name, "child")) self.payload(r.of.*, .optional) else unsupported,
        .error_union => return if (std.mem.eql(u8, name, "payload")) self.payload(r.of.*, .error_union) else unsupported,
        .array => return if (std.mem.eql(u8, name, "child")) self.indexed(r.of.*, {}) else unsupported,
        .function => {
            if (r.of.* != .function) return if (r.of.* == .unknown) r.of.* else unsupported;
            if (std.mem.eql(u8, name, "param_types")) return .{ .reflected = .{ .of = r.of, .at = .params } };
            if (!std.mem.eql(u8, name, "return_type")) return unsupported;
            // `?type`: null for a result that depends on an argument.
            const result = try self.returnTypeOf(r.of.function);
            if (result == .unknown) return result;
            return .{ .optional = try self.boxed(result) };
        },
        .params, .part => return unsupported,
    }
}

/// `param_types[i]` of a reflected function, `?type` as Zig gives it: the parameter's
/// declared type, null (unknown here) for `anytype` or a type that depends on an argument.
fn reflectedElement(self: *Facts, r: Reflected, tree: *const Ast, index_node: Ast.Node.Index) ResolveError!Value {
    if (r.at != .params or r.of.* != .function) return .{ .unknown = .unsupported };
    if (tree.nodeTag(index_node) != .number_literal) return .{ .unknown = .comptime_dependent };
    const position = std.fmt.parseInt(usize, tree.tokenSlice(tree.nodeMainToken(index_node)), 0) catch return .{ .unknown = .unsupported };
    const decl = r.of.function;
    const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, self.project.models[decl.file.raw()].declarations[decl.index].node) orelse return .{ .unknown = .unsupported }; // safe: enum identities index their owning frozen tables without narrowing.
    var it = function.iterate(target_tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at != position) continue;
        const type_expr = param.type_expr orelse return .{ .unknown = .comptime_dependent };
        const value = try self.resolve(decl.file, type_expr);
        if (value == .unknown) return value;
        return .{ .optional = try self.boxed(value) };
    }
    return .{ .unknown = .unsupported };
}

/// A function's declared result as a type, `!T` an error union of it.
fn returnTypeOf(self: *Facts, decl: Decl) ResolveError!Value {
    const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, self.project.models[decl.file.raw()].declarations[decl.index].node) orelse return .{ .unknown = .unsupported }; // safe: enum identities index their owning frozen tables without narrowing.
    const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
    const result = try self.resolve(decl.file, result_node);
    if (result == .unknown) return result;
    if (target_tree.tokenTag(target_tree.firstToken(result_node) - 1) == .bang) return .{ .error_union = try self.boxed(result) };
    return result;
}

/// Whether a function takes a parameter only a call settles: `comptime` or `anytype`.
fn isGeneric(tree: *const Ast, function: Ast.full.FnProto) bool {
    var it = function.iterate(tree);
    while (it.next()) |param| {
        if (param.anytype_ellipsis3 != null) return true;
        if (param.comptime_noalias) |token| if (tree.tokenTag(token) == .keyword_comptime) return true;
        if (param.type_expr) |t| if (tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type")) return true;
    }
    return false;
}

/// What calling the generic function `decl` returns with its parameters bound to the call's
/// arguments, read in `env` when the call is itself inside a generic being read: the type a
/// type function returns as an expression (`@typeInfo(T).pointer.child`), or a result type
/// written in terms of its parameters. Null when that reading gives nothing known, for the
/// caller's other means.
fn evaluateCall(self: *Facts, env: ?*const Env, file: Project.FileId, call: Ast.full.Call, decl: Decl) ResolveError!?Value {
    const depth = if (env) |e| e.depth + 1 else 0;
    if (depth == 8) return null;
    const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const record = self.project.models[decl.file.raw()].declarations[decl.index]; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, record.node) orelse return null;
    if (!isGeneric(target_tree, function)) return null;
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var args: std.ArrayList(Value) = .empty;
    // A method called on a value takes that value as its first parameter.
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const receiver = try self.resolveIn(env, file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        const on_value = switch (receiver) {
            .instance => true,
            .pointer => |p| p.* == .instance,
            else => false,
        };
        if (on_value) try args.append(self.gpa, receiver);
    }
    for (call.ast.params) |arg| try args.append(self.gpa, try self.resolveIn(env, file, arg));
    const bound = try self.gpa.create(Env);
    bound.* = .{ .function = decl, .args = args.items, .depth = depth };
    const result_node = function.ast.return_type.unwrap() orelse return null;
    const result_tree = target_tree;
    const returns_type = result_tree.nodeTag(result_node) == .identifier and std.mem.eql(u8, result_tree.tokenSlice(result_tree.nodeMainToken(result_node)), "type");
    if (returns_type) {
        const returned = finalReturn(result_tree, self.project.models[decl.file.raw()].node_parents, record) orelse return null; // safe: enum identities index their owning frozen tables without narrowing.
        // A container is the template's, which the call makes: read by the existing means.
        var container_buffer: [2]Ast.Node.Index = undefined;
        if (result_tree.fullContainerDecl(&container_buffer, returned) != null) return null;
        const value = try self.resolveIn(bound, decl.file, returned);
        return if (value == .unknown) null else value;
    }
    const value = try self.resolveIn(bound, decl.file, result_node);
    if (value == .unknown) return null;
    if (result_tree.tokenTag(result_tree.firstToken(result_node) - 1) == .bang) return .{ .error_union = try self.boxed(try self.valueOf(value)) };
    return try self.valueOf(value);
}

/// A value of the type `value` is: an instance of a container, also inside an error union or
/// an optional.
fn valueOf(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .error_union => |inner| .{ .error_union = try self.boxed(try self.valueOf(inner.*)) },
        .optional => |inner| .{ .optional = try self.boxed(try self.valueOf(inner.*)) },
        else => self.instance(value),
    };
}

/// The parameters a type function passes on changed where a `return` before its final one
/// (`body`'s `last` statement) calls it again: a bit per position whose argument is not that
/// same parameter. Null when an earlier `return` gives anything but such a call.
fn recursion(self: *const Facts, decl: Decl, body: Ast.Node.Index, last: Ast.Node.Index) ?u64 {
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const model = &self.project.models[decl.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, model.declarations[decl.index].node) orelse return null;
    var params: [64]Ast.TokenIndex = undefined;
    var count: usize = 0;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        if (count == params.len) return null;
        params[count] = param.name_token orelse return null;
        count += 1;
    }
    var changed: u64 = 0;
    const first = tree.firstToken(body);
    const end = tree.nodeMainToken(last);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"return") continue;
        const early: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        const at = tree.nodeMainToken(early);
        if (at < first or at >= end) continue;
        const operand = tree.nodeData(early).opt_node.unwrap() orelse return null;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, operand) orelse return null;
        if (tree.nodeTag(call.ast.fn_expr) != .identifier) return null;
        const callee = (model.reference(call.ast.fn_expr) orelse return null).declaration orelse return null;
        if (callee != decl.index or call.ast.params.len != count) return null;
        for (call.ast.params, 0..) |arg, position| {
            const same_parameter = tree.nodeTag(arg) == .identifier and if (model.reference(arg)) |ref| if (ref.declaration) |index| model.declarations[index].token == params[position] else false else false;
            if (!same_parameter) changed |= @as(u64, 1) << @intCast(position); // safe: at most 64 parameters, checked above.
        }
    }
    return changed;
}

/// The operand of a function body's one `return`, its final statement.
fn finalReturn(tree: *const Ast, parents: []const ?Ast.Node.Index, record: Model.Declaration) ?Ast.Node.Index {
    var fn_node = record.node;
    if (tree.nodeTag(fn_node) != .fn_decl) fn_node = parents[@backingInt(fn_node)] orelse return null; // safe: a node index indexes its own tree's parent table.
    if (tree.nodeTag(fn_node) != .fn_decl) return null;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return null;
    if (statements.len == 0 or tree.nodeTag(statements[statements.len - 1]) != .@"return") return null;
    const last = statements[statements.len - 1];
    for (tree.firstToken(body)..tree.nodeMainToken(last)) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_return) return null; // safe: the body's token range lies inside the file's token table.
    }
    return tree.nodeData(last).opt_node.unwrap();
}

/// `node` read with `env`'s bindings: a parameter of the function being read is its argument,
/// a constant declared in its body is what initialises it, and what is built from them is
/// built again; anything else resolves as it does everywhere.
fn resolveIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const e = env orelse return self.resolve(file, node);
    if (!file.eql(e.function.file)) return self.resolve(file, node);
    if (self.remaining == 0) return .{ .unknown = .budget };
    self.remaining -= 1;
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const model = &self.project.models[file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return self.resolve(file, node);
            const index = ref.declaration orelse return self.resolve(file, node);
            const record = model.declarations[index];
            const function_scope = self.scopeNode(e.function);
            if (record.kind == .parameter and model.scopes[record.scope].node == function_scope) {
                if (self.parameterPosition(file, e.function, record.token)) |position| {
                    if (position < e.args.len) return e.args[position];
                }
                return .{ .unknown = .comptime_dependent };
            }
            if (record.kind == .variable and self.inside(file, record.scope, function_scope)) {
                const variable = tree.fullVarDecl(record.node) orelse return self.resolve(file, node);
                if (variable.ast.type_node.unwrap()) |t| {
                    const type_value = try self.resolveIn(env, file, t);
                    if (type_value != .primitive or !std.mem.eql(u8, type_value.primitive, "type")) return self.instance(type_value);
                }
                if (variable.ast.init_node.unwrap()) |init| return self.resolveIn(env, file, init);
            }
            return self.resolve(file, node);
        },
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            return self.memberValue(try self.resolveIn(env, file, data[0]), try self.memberName(tree.tokenSlice(data[1])));
        },
        .unwrap_optional => return self.payload(try self.resolveIn(env, file, tree.nodeData(node).node_and_token[0]), .optional),
        .@"try" => return self.payload(try self.resolveIn(env, file, tree.nodeData(node).node), .error_union),
        .grouped_expression => return self.resolveIn(env, file, tree.nodeData(node).node_and_token[0]),
        .@"comptime", .@"nosuspend" => return self.resolveIn(env, file, tree.nodeData(node).node),
        .optional_type => return .{ .optional = try self.boxed(try self.resolveIn(env, file, tree.nodeData(node).node)) },
        .error_union => return .{ .error_union = try self.boxed(try self.resolveIn(env, file, tree.nodeData(node).node_and_node[1])) },
        .@"switch", .switch_comma, .@"if" => if (try self.branches(env, file, node)) |value| return value,
        .array_access => {
            const operands = tree.nodeData(node).node_and_node;
            const base = try self.resolveIn(env, file, operands[0]);
            return self.elementOf(base, tree, operands[1]);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(tree, node, &buffer);
            if (std.mem.eql(u8, name, "@TypeOf") and args.len == 1) return self.map(try self.resolveIn(env, file, args[0]), {}, typeOf);
            if (std.mem.eql(u8, name, "@typeInfo") and args.len == 1) return self.reflect(try self.resolveIn(env, file, args[0]));
            if (std.mem.eql(u8, name, "@as") and args.len == 2) return self.instance(try self.resolveIn(env, file, args[0]));
            return self.resolve(file, node);
        },
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node).?;
            const callee = try self.resolveIn(env, file, call.ast.fn_expr);
            if (callee != .function) return self.callResult(callee, {});
            if (try self.evaluateCall(env, file, call, callee.function)) |value| return value;
            var result = try self.callResult(callee, {});
            // A container a type function makes here is made with this reading's bindings.
            if (result == .container and result.container.symbolic) {
                const made = try self.gpa.create(Made);
                made.* = .{ .function = callee.function, .file = file, .call = node, .env = e };
                result.container.made_by = made;
            }
            return result;
        },
        else => {},
    }
    if (tree.fullPtrType(node)) |ptr| return .{ .pointer = try self.boxed(try self.resolveIn(env, file, ptr.ast.child_type)) };
    if (tree.fullArrayType(node)) |array| return .{ .array = try self.boxed(try self.resolveIn(env, file, array.ast.elem_type)) };
    return self.resolve(file, node);
}

/// Whether `scope` lies inside the function whose node is `function_node`.
fn inside(self: *const Facts, file: Project.FileId, scope: u32, function_node: Ast.Node.Index) bool {
    const scopes = self.project.models[file.raw()].scopes; // safe: enum identities index their owning frozen tables without narrowing.
    var at: ?u32 = scope;
    while (at) |s| : (at = scopes[s].parent) {
        if (scopes[s].kind == .function) return scopes[s].node == function_node;
    }
    return false;
}

/// The position of the parameter named by `token` in `function`'s list.
fn parameterPosition(self: *const Facts, file: Project.FileId, function: Decl, token: Ast.TokenIndex) ?usize {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, self.project.models[file.raw()].declarations[function.index].node) orelse return null; // safe: enum identities index their owning frozen tables without narrowing.
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) if (param.name_token == token) return position;
    return null;
}

/// The function declaring parameter `decl`, and its position, when it is `anytype` or a
/// `comptime` type: a parameter only its calls settle.
fn settledByCalls(self: *Facts, decl: Decl) ResolveError!?usize {
    const model = &self.project.models[decl.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const record = model.declarations[decl.index];
    const function = self.functionOf(decl) orelse return null;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, model.declarations[function.index].node) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token != record.token) continue;
        if (param.anytype_ellipsis3 != null) return position;
        // A `type` parameter is comptime, written so or not.
        const type_expr = param.type_expr orelse return null;
        if (tree.nodeTag(type_expr) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(type_expr)), "type")) return position;
        return null;
    }
    return null;
}

fn functionOf(self: *const Facts, parameter: Decl) ?Decl {
    const model = &self.project.models[parameter.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const scope = model.scopes[model.declarations[parameter.index].scope];
    if (scope.kind != .function) return null;
    for (model.declarations, 0..) |d, i| {
        if (d.kind != .function) continue;
        const candidate: Decl = .{ .file = parameter.file, .index = @intCast(i) }; // safe: declaration indexes come from the bounded frozen per-file model.
        if (self.scopeNode(candidate) == scope.node) return candidate;
    }
    return null;
}

/// The node a function's scope is recorded at: its declaration with a body, else its prototype.
fn scopeNode(self: *const Facts, function: Decl) Ast.Node.Index {
    const model = &self.project.models[function.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const proto = model.declarations[function.index].node;
    const tree = &self.project.files[function.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    if (model.node_parents[@backingInt(proto)]) |parent| if (tree.nodeTag(parent) == .fn_decl) return parent; // safe: a node index indexes its own tree's parent table.
    return proto;
}

/// A generic parameter's value as the project's own calls bind it: the union of their
/// arguments at its position, when every use of the function is a call within the project
/// and its consumers cannot call it by name. Anything else stays unknown.
fn boundByCallers(self: *Facts, parameter: Decl, position: usize) ResolveError!Value {
    const function = self.functionOf(parameter) orelse return .{ .unknown = .comptime_dependent };
    const found = (try self.callArguments(function, position)) orelse return .{ .unknown = .comptime_dependent };
    // A call that passes something from a module the build does not have is not compiled.
    var values: std.ArrayList(Value) = .empty;
    for (found) |value| if (!absent(value)) try values.append(self.gpa, value);
    if (values.items.len == 0) return .{ .unknown = .comptime_dependent };
    return self.choose(values.items);
}

/// Whether a value comes from a module the build does not have, itself or through what
/// wraps it.
fn absent(value: Value) bool {
    return switch (value) {
        .unknown => |why| why == .absent,
        .pointer, .array, .optional, .error_union => |inner| absent(inner.*),
        else => false,
    };
}

/// The arguments every call of `function` in the project passes at `position`, or null when
/// the function is used other than by a call, or when a consumer can call it by name.
fn callArguments(self: *Facts, function: Decl, position: usize) ResolveError!?[]const Value {
    const model = &self.project.models[function.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const record = model.declarations[function.index];
    if (record.public and try self.exportedFunction(function)) return null;
    const name_token = record.token;
    const name = self.project.files[function.file.raw()].tree.tokenSlice(name_token); // safe: enum identities index their owning frozen tables without narrowing.
    var values: std.ArrayList(Value) = .empty;
    for (self.project.files, self.project.models, 0..) |*file, *file_model, raw| {
        if (file.status != .parsed) continue;
        // A private function is used in its own file only; a file outside the package
        // reaches it only through a module's exported names, which this one is not among.
        const id: Project.FileId = .fromRaw(@intCast(raw)); // safe: file indexes are bounded by the frozen project table.
        const own = id.eql(function.file);
        if (!record.public and !own) continue;
        if (!self.project.inputs[raw].selected) continue;
        const tree = &file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
            const names_it = switch (tag) {
                .identifier => blk: {
                    const ref = file_model.reference(node) orelse break :blk false;
                    break :blk own and ref.declaration != null and ref.declaration.? == function.index;
                },
                .field_access => std.mem.eql(u8, tree.tokenSlice(tree.nodeData(node).node_and_token[1]), name),
                else => false,
            };
            if (!names_it) continue;
            // The declaration's own name token is no use of it, nor an enum's field of that name.
            if (tag == .identifier and tree.nodeMainToken(node) == name_token and own) continue;
            if (tag == .identifier and enumField(tree, file_model, node)) continue;
            const parent = file_model.node_parents[i] orelse return null;
            // `@TypeOf(f)` asks its type: no use of it that passes it on.
            if (isTypeQuery(tree, parent)) continue;
            var receiver: usize = 0;
            // Whether this use calls what it names. A value's method is reached only by a call:
            // Zig has no bound methods, so a value's member used otherwise is its field.
            var callee_buffer: [1]Ast.Node.Index = undefined;
            var tuple_buffer: [2]Ast.Node.Index = undefined;
            const callee = callParams(tree, parent, node, &callee_buffer, &tuple_buffer) != null;
            // A member written to or read as a number is a field: a function is neither.
            if (tag == .field_access and !callee and fieldUse(tree, parent, node)) continue;
            if (tag == .field_access) {
                const target = try self.resolve(id, tree.nodeData(node).node_and_token[0]);
                // What the name is a member of: each alternative that can have members. One
                // that does not resolve may be this function's container.
                const parts = try self.holders(target);
                var calls_it = false;
                for (parts) |part| {
                    const container: Container, const on_value = switch (part) {
                        .container => |c| .{ c, false },
                        .instance => |c| .{ c, true },
                        // A pointer is a value: its method takes it as the first parameter.
                        .pointer => |pointed| switch (pointed.*) {
                            .instance, .container => |c| .{ c, true },
                            .unknown => if (!callee or try self.cannotBe(tree, parent, node, function)) continue else return null,
                            else => continue,
                        },
                        // A path of declarations from a module's root reaches only what the
                        // module exports by name, which this function's container is not.
                        .unknown => if (try self.cannotBe(tree, parent, node, function) or self.throughModule(id, tree.nodeData(node).node_and_token[0]) or (!callee and try self.runtimeValue(id, tree.nodeData(node).node_and_token[0], 0))) continue else return null,
                        // `void`, a number or an error has no member to call.
                        else => continue,
                    };
                    const found = self.member(container, name) orelse continue;
                    if (!std.meta.eql(found, function)) continue;
                    calls_it = true;
                    if (on_value) receiver = 1;
                }
                if (!calls_it) continue;
            }
            const params = callParams(tree, parent, node, &callee_buffer, &tuple_buffer) orelse return null;
            if (position < receiver) {
                try values.append(self.gpa, try self.resolve(id, tree.nodeData(node).node_and_token[0]));
                continue;
            }
            if (position - receiver >= params.len) return null;
            try values.append(self.gpa, try self.resolve(id, params[position - receiver]));
        }
    }
    return values.items;
}

/// The arguments `parent` passes when it calls what `node` names: `f(a, b)`, or
/// `@call(modifier, f, .{ a, b })`. Null when `parent` does not call it.
fn callParams(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index, call_buffer: *[1]Ast.Node.Index, tuple_buffer: *[2]Ast.Node.Index) ?[]const Ast.Node.Index {
    if (tree.fullCall(call_buffer, parent)) |call| return if (call.ast.fn_expr == node) call.ast.params else null;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, parent, &buffer);
    if (args.len != 3 or args[1] != node or !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@call")) return null;
    const tuple = tree.fullArrayInit(tuple_buffer, args[2]) orelse return null;
    if (tuple.ast.type_expr != .none) return null;
    return tuple.ast.elements;
}

/// Whether `parent` uses its operand `node` as only a field can be used: as the target of an
/// assignment, or as an operand of arithmetic, a comparison or a logical operator.
fn fieldUse(tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(parent)) {
        .assign, .assign_mul, .assign_div, .assign_mod, .assign_add, .assign_sub, .assign_shl, .assign_shl_sat, .assign_shr, .assign_bit_and, .assign_bit_xor, .assign_bit_or, .assign_mul_wrap, .assign_add_wrap, .assign_sub_wrap, .assign_mul_sat, .assign_add_sat, .assign_sub_sat => tree.nodeData(parent).node_and_node[0] == node,
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .bool_and, .bool_or, .bool_not, .negation, .negation_wrap, .bit_not, .mul, .mul_wrap, .mul_sat, .div, .mod, .shl, .shl_sat, .shr, .bit_and, .bit_or, .bit_xor, .add, .add_wrap, .add_sat, .sub, .sub_wrap, .sub_sat => true,
        else => false,
    };
}

/// What a member access's receiver can be, one by one: each alternative, and a pointer to a
/// choice as a pointer to each of its alternatives.
fn holders(self: *Facts, value: Value) ResolveError![]const Value {
    var list: std.ArrayList(Value) = .empty;
    const outer: []const Value = if (value == .alternatives) value.alternatives else &.{value};
    for (outer) |one| {
        if (one == .pointer and one.pointer.* == .alternatives) {
            for (one.pointer.alternatives) |inner| try list.append(self.gpa, .{ .pointer = try self.boxed(inner) });
        } else try list.append(self.gpa, one);
    }
    return list.items;
}

/// Whether `node` is a value the program holds at run time, never a type or a namespace (below).
/// Zig's `@field` on such a value reaches only fields, never a declaration.
pub fn runtime(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    return self.runtimeValue(file, node, 0);
}

/// Whether `node` is a value the program holds at run time, never a type or a namespace: an
/// address taken, a `var`, a parameter declared with a type other than `type`, a `const`
/// declared with such a type or initialized by such a value, or a field of one. A field of a
/// value is a value unless a `comptime` field holds it, so a name some container in the
/// project declares as a `comptime` field is left unknown.
fn runtimeValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!bool {
    if (depth == 32) return false;
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const model = &self.project.models[file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    switch (tree.nodeTag(node)) {
        .address_of => return true,
        .grouped_expression => return self.runtimeValue(file, tree.nodeData(node).node_and_token[0], depth + 1),
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            if (try self.comptimeField(try self.memberName(tree.tokenSlice(data[1])))) return false;
            return self.runtimeValue(file, data[0], depth + 1);
        },
        .identifier => {
            const ref = model.reference(node) orelse return false;
            const record = model.declarations[ref.declaration orelse return false];
            switch (record.kind) {
                .parameter => {
                    const function = self.functionOf(.{ .file = file, .index = ref.declaration.? }) orelse return false;
                    var fn_buffer: [1]Ast.Node.Index = undefined;
                    const proto = tree.fullFnProto(&fn_buffer, model.declarations[function.index].node) orelse return false;
                    var it = proto.iterate(tree);
                    while (it.next()) |param| {
                        if (param.name_token != record.token) continue;
                        // `anytype` binds a value or a type; dereferenced, it is a pointer.
                        const type_expr = param.type_expr orelse return self.dereferenced(.{ .file = file, .index = ref.declaration.? });
                        return !typeKeyword(tree, type_expr);
                    }
                    return false;
                },
                .variable => {
                    const variable = tree.fullVarDecl(record.node) orelse return false;
                    if (variable.comptime_token != null) return false;
                    if (variable.ast.type_node.unwrap()) |t| return !typeKeyword(tree, t);
                    if (tree.tokenTag(variable.ast.mut_token) == .keyword_var) return true;
                    const init = variable.ast.init_node.unwrap() orelse return false;
                    return self.runtimeValue(file, init, depth + 1);
                },
                else => return false,
            }
        },
        else => return false,
    }
}

/// Whether the program dereferences the declaration `decl` somewhere in its file (`p.*`),
/// which only a pointer allows.
fn dereferenced(self: *Facts, decl: Decl) ResolveError!bool {
    const done = try self.dereferences_found.getOrPut(self.gpa, decl.file);
    if (!done.found_existing) {
        const tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
        const model = &self.project.models[decl.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .deref) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
            const operand = tree.nodeData(node).node;
            if (tree.nodeTag(operand) != .identifier) continue;
            const ref = model.reference(operand) orelse continue;
            const index = ref.declaration orelse continue;
            try self.dereferences.put(self.gpa, .{ .file = decl.file, .index = index }, {});
        }
    }
    return self.dereferences.contains(decl);
}

fn typeKeyword(tree: *const Ast, node: Ast.Node.Index) bool {
    return tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "type");
}

/// Whether any container in the project declares a `comptime` field named `name`.
fn comptimeField(self: *Facts, name: []const u8) ResolveError!bool {
    if (self.comptime_fields == null) {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (self.project.files, self.project.models) |*file, *model| {
            if (file.status != .parsed) continue;
            for (model.declarations) |d| {
                if (d.kind != .field) continue;
                const field = file.tree.fullContainerField(d.node) orelse continue;
                if (field.comptime_token != null) try names.put(self.gpa, d.name, {});
            }
        }
        self.comptime_fields = names;
    }
    return self.comptime_fields.?.contains(name);
}

/// Whether the call `parent` makes through the member access `node` cannot be `function`:
/// it passes a number of arguments the function takes neither as a method nor by name.
fn cannotBe(self: *Facts, tree: *const Ast, parent: Ast.Node.Index, node: Ast.Node.Index, function: Decl) ResolveError!bool {
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, parent) orelse return false;
    if (call.ast.fn_expr != node) return false;
    const target_tree = &self.project.files[function.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = target_tree.fullFnProto(&fn_buffer, self.project.models[function.file.raw()].declarations[function.index].node) orelse return false; // safe: enum identities index their owning frozen tables without narrowing.
    var count: usize = 0;
    var it = proto.iterate(target_tree);
    while (it.next()) |_| count += 1;
    return call.ast.params.len != count and call.ast.params.len + 1 != count;
}

/// Whether `node` is a path of declarations from a module imported by name: `reactor.Loop`.
fn throughModule(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const model = &self.project.models[file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    var at = node;
    while (tree.nodeTag(at) == .field_access) at = tree.nodeData(at).node_and_token[0];
    if (tree.nodeTag(at) != .identifier) return false;
    const ref = model.reference(at) orelse return false;
    const index = ref.declaration orelse return false;
    const record = model.declarations[index];
    if (record.kind != .variable) return false;
    const variable = tree.fullVarDecl(record.node) orelse return false;
    const init = variable.ast.init_node.unwrap() orelse return false;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, init, &buffer);
    if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "@import")) return false;
    return !std.mem.endsWith(u8, tree.tokenSlice(tree.nodeMainToken(args[0])), ".zig\"");
}

/// Whether `node` is the name of an enum's field, which Zig's syntax tree holds where a
/// struct's field holds its type.
fn enumField(tree: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    const field = model.node_parents[@backingInt(node)] orelse return false; // safe: a node index indexes its own tree's parent table.
    const full = tree.fullContainerField(field) orelse return false;
    if (full.ast.type_expr.unwrap() != node) return false;
    const container = model.node_parents[@backingInt(field)] orelse return false; // safe: a node index indexes its own tree's parent table.
    return tree.tokenTag(tree.nodeMainToken(container)) == .keyword_enum;
}

fn isTypeQuery(tree: *const Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@TypeOf"),
        else => false,
    };
}

/// Whether consumers of the package reach `function` by name: it is public and its container
/// is reached through public declarations from a module root another file imports by name.
fn exportedFunction(self: *Facts, function: Decl) ResolveError!bool {
    const model = &self.project.models[function.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    var scope = model.declarations[function.index].scope;
    while (model.scopes[scope].kind != .container and model.scopes[scope].kind != .file) scope = model.scopes[scope].parent orelse return true;
    const set = try self.exportedContainers();
    return set.contains(.{ .file = function.file, .scope = scope });
}

fn exportedContainers(self: *Facts) ResolveError!*const std.AutoHashMapUnmanaged(Container, void) {
    if (self.exported) |*set| return set;
    var set: std.AutoHashMapUnmanaged(Container, void) = .empty;
    var queue: std.ArrayList(Container) = .empty;
    // A module root: a file imported by a module name rather than a path.
    for (self.project.imports) |edge| {
        if (std.mem.endsWith(u8, edge.spelling, ".zig") or std.mem.eql(u8, edge.spelling, "std") or std.mem.eql(u8, edge.spelling, "builtin")) continue;
        const root: Container = .{ .file = edge.target, .scope = 0 };
        if ((try set.getOrPut(self.gpa, root)).found_existing) continue;
        try queue.append(self.gpa, root);
    }
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const container = queue.items[next];
        const model = &self.project.models[container.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
        for (model.declarations, 0..) |d, i| {
            if (d.scope != container.scope or !d.public or d.kind != .variable) continue;
            const value = try self.declaration(.{ .file = container.file, .index = @intCast(i) }); // safe: declaration indexes come from the bounded frozen per-file model.
            const reached = switch (value) {
                .container, .instance => |c| c,
                else => continue,
            };
            const plain: Container = .{ .file = reached.file, .scope = reached.scope };
            if ((try set.getOrPut(self.gpa, plain)).found_existing) continue;
            try queue.append(self.gpa, plain);
        }
    }
    self.exported = set;
    return &self.exported.?;
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

test "a call that passes what a module the build does not have gives binds nothing" {
    const source = "const k = @import(\"kernels\");\nconst S = struct { used: usize };\nfn local() S { return .{ .used = 0 }; }\nfn folded(comptime fold: anytype) usize { const f = fold(); return f.used; }\npub fn a() usize { return folded(local); }\npub fn b() usize { return folded(k.fold); }";
    for ([_]bool{ false, true }) |absent_kernels| {
        const names: []const []const u8 = if (absent_kernels) &.{"kernels"} else &.{};
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source, .absent = names }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
        defer facts.deinit();
        const model = &project.models[0];
        const f = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, "f")) break d;
        } else unreachable; // unreachable: the source declares `f`
        const init = project.files[0].tree.fullVarDecl(f.node).?.ast.init_node.unwrap().?;
        const value = try facts.resolve(Project.FileId.fromRaw(0), init); // safe: one source.
        // Unmapped, `k.fold` is unknown and so is the binding; absent, its call is not compiled.
        try std.testing.expectEqual(absent_kernels, value == .instance);
    }
}

/// The type a struct literal takes from where it is written, as Zig gives it a result type: a
/// typed literal's own; a declaration's written type; an assignment's target; a call's
/// parameter, read with a made container's arguments for its methods; its function's result
/// for a `return`; a typed literal's field or array's element; `@as`; and through a grouping,
/// a branch or a block's `break`. `.scalar` where nothing gives it one (an untyped `const`, an
/// `anytype` argument): it is then an anonymous struct. Unknown where the place does not
/// resolve.
pub fn literalType(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    return self.placeType(file, node, 0);
}

fn placeType(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) ResolveError!Value {
    if (depth == 32) return .{ .unknown = .budget };
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const model = &self.project.models[file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| if (literal.ast.type_expr.unwrap()) |t| return self.resolve(file, t);
    const parent = model.node_parents[@backingInt(node)] orelse return .{ .unknown = .unsupported }; // safe: a node index indexes its own tree's parent table.
    if (tree.fullVarDecl(parent)) |variable| {
        if (variable.ast.init_node.unwrap() != node) return .{ .unknown = .unsupported };
        return if (variable.ast.type_node.unwrap()) |t| try self.resolve(file, t) else .scalar;
    }
    // A field's default value takes the field's type.
    if (tree.fullContainerField(parent)) |field| {
        if (field.ast.value_expr.unwrap() != node) return .{ .unknown = .unsupported };
        return if (field.ast.type_expr.unwrap()) |t| try self.resolve(file, t) else .{ .unknown = .unsupported };
    }
    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, parent)) |call| {
        const position = std.mem.findScalar(Ast.Node.Index, call.ast.params, node) orelse return .{ .unknown = .unsupported };
        return self.parameterType(file, call, position);
    }
    var parent_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&parent_buffer, parent) != null) {
        const whole = try self.placeType(file, parent, depth + 1);
        if (whole == .unknown or whole == .scalar) return whole;
        const name = try self.memberName(tree.tokenSlice(tree.firstToken(node) - 2));
        // A literal coerces through an optional or an error union; `&.{}` gives a pointer to one.
        var holder = whole;
        while (true) holder = switch (holder) {
            .optional, .error_union, .pointer => |inner| inner.*,
            else => break,
        };
        const container = switch (holder) {
            .container, .instance => |c| c,
            .unknown => return holder,
            else => return .{ .unknown = .unsupported },
        };
        const field = self.member(container, name) orelse return .{ .unknown = .unresolved };
        return self.declaration(field);
    }
    if (tree.fullArrayInit(&parent_buffer, parent)) |array| {
        const whole = if (array.ast.type_expr.unwrap()) |t| try self.resolve(file, t) else try self.placeType(file, parent, depth + 1);
        return switch (whole) {
            // An array literal given where a slice is taken (`&.{ a, b }`) holds its elements.
            .array, .pointer => |each| each.*,
            .unknown => whole,
            else => .{ .unknown = .unsupported },
        };
    }
    switch (tree.nodeTag(parent)) {
        .assign => return if (tree.nodeData(parent).node_and_node[1] == node) try self.resolve(file, tree.nodeData(parent).node_and_node[0]) else .{ .unknown = .unsupported },
        .address_of, .grouped_expression, .@"orelse", .@"catch", .@"if", .if_simple, .@"switch", .switch_comma, .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => return self.placeType(file, parent, depth + 1),
        .@"break" => {
            const label = tree.nodeData(parent).opt_token_and_opt_node[0].unwrap() orelse return .{ .unknown = .unsupported };
            var at: ?Ast.Node.Index = model.node_parents[@backingInt(parent)]; // safe: a node index indexes its own tree's parent table.
            while (at) |candidate| : (at = model.node_parents[@backingInt(candidate)]) { // safe: a node index indexes its own tree's parent table.
                const tag = tree.nodeTag(candidate);
                if (tag != .block and tag != .block_semicolon and tag != .block_two and tag != .block_two_semicolon) continue;
                const first = tree.firstToken(candidate);
                if (first >= 2 and tree.tokenTag(first - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(first - 2), tree.tokenSlice(label))) return self.placeType(file, candidate, depth + 1);
            }
            return .{ .unknown = .unsupported };
        },
        .@"return" => {
            var at: ?Ast.Node.Index = model.node_parents[@backingInt(parent)]; // safe: a node index indexes its own tree's parent table.
            while (at) |candidate| : (at = model.node_parents[@backingInt(candidate)]) { // safe: a node index indexes its own tree's parent table.
                if (tree.nodeTag(candidate) != .fn_decl) continue;
                var fn_buffer: [1]Ast.Node.Index = undefined;
                const function = tree.fullFnProto(&fn_buffer, tree.nodeData(candidate).node_and_node[0]) orelse return .{ .unknown = .unsupported };
                const result = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
                return self.resolve(file, result);
            }
            return .{ .unknown = .unsupported };
        },
        else => {},
    }
    var args_buffer: [2]Ast.Node.Index = undefined;
    const args = builtinArgs(tree, parent, &args_buffer);
    if (args.len == 2 and args[1] == node and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(parent)), "@as")) return self.resolve(file, args[0]);
    return .{ .unknown = .unsupported };
}

/// The written type of a call's argument at `position`: the callee's parameter (a method's
/// receiver first), a made container's method read with the arguments that made it.
/// `.scalar` for `anytype`, which takes the argument's own type.
fn parameterType(self: *Facts, file: Project.FileId, call: Ast.full.Call, position: usize) ResolveError!Value {
    const tree = &self.project.files[file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    const callee = try self.resolve(file, call.ast.fn_expr);
    if (callee == .unknown) return callee;
    if (callee != .function) return .{ .unknown = .unsupported };
    const decl = callee.function;
    var receiver: usize = 0;
    var made: ?*const Made = null;
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const on = try self.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        const container: ?Container = switch (on) {
            .instance => |c| c,
            .pointer => |p| switch (p.*) {
                .instance => |c| c,
                else => null,
            },
            else => null,
        };
        if (container) |c| {
            receiver = 1;
            if (c.made_by) |m| if (decl.file.eql(c.file) and self.project.models[decl.file.raw()].declarations[decl.index].scope == c.scope) { // safe: enum identities index their owning frozen tables without narrowing.
                made = m;
            };
        }
    }
    const target_tree = &self.project.files[decl.file.raw()].tree; // safe: enum identities index their owning frozen tables without narrowing.
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, self.project.models[decl.file.raw()].declarations[decl.index].node) orelse return .{ .unknown = .unsupported }; // safe: enum identities index their owning frozen tables without narrowing.
    var it = function.iterate(target_tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at != position + receiver) continue;
        const type_expr = param.type_expr orelse return .scalar;
        if (made) |m| return self.substituted(decl.file, type_expr, m);
        // Written in terms of a `comptime T: type` parameter: the call's argument for it.
        if (try self.written(.{ .file = file, .call = call, .decl = decl, .function = function, .receiver = receiver }, type_expr, 0)) |bound| return bound;
        return self.resolve(decl.file, type_expr);
    }
    return .{ .unknown = .unsupported };
}
