//! Conservative declaration and shape facts over the frozen AST/ZIR project.
//! Unknown comptime and cyclic aliases remain unknown; no spelling guesses.
const std = @import("std");
const aegis = @import("aegis");
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Ast = std.zig.Ast;
const Facts = @This();

project: *const Project,
gpa: std.mem.Allocator,
/// The module names of the libraries the analyses know by their declarations (aegis's), as a
/// program imports them: their files, like std's, are not the program's (`program`).
known: []const []const u8 = &.{},
cache: std.AutoHashMapUnmanaged(Settled, Value) = .empty,
active: std.AutoHashMapUnmanaged(Settled, void) = .empty,
/// The sets of comptime `bool` parameters' values that the paths read so far settle, each once.
settled: std.ArrayList(Assumptions) = .empty,
/// The set in force: what the path to the node being read settles; null for none. A value is
/// read as Zig analyses the node, in the instantiations where its path is taken.
assumed: ?Assumptions.Id = null,
/// What each generic function copies of its parameters' values, found once (`parameterCopies`).
copies: ?std.AutoHashMapUnmanaged(Decl, []const ParameterCopy) = null,
/// The names those functions are declared under, for a quick look before a callee is resolved.
copier_names: std.StringHashMapUnmanaged(void) = .empty,
/// The places the copies `directCopies` finds in a value chosen or wrapped read, each with
/// its copy's declaration: a copy its bindings decide (`boundAtBinding`).
bound_places: std.AutoHashMapUnmanaged(struct { site: Key, place: Ast.Node.Index }, void) = .empty,
/// The builtins `scalarCasts` finds: casts each binding decides (`castAtBinding`).
cast_sites: std.AutoHashMapUnmanaged(Key, void) = .empty,
/// Whether a file declares any `comptime` parameter of type `bool`, found per file once.
conditional_files: std.AutoHashMapUnmanaged(Project.FileId, bool) = .empty,
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
/// Per-run state rules keep across files, by the key they name it with (`memo`).
memos: std.AutoHashMapUnmanaged(usize, *anyopaque) = .empty,
/// Every member access in the program's files, by the member's name, found once (`memberUses`).
member_uses: ?std.StringHashMapUnmanaged(std.ArrayList(Key)) = null,
remaining: usize = 100_000,

pub const Key = struct { file: Project.FileId, node: Ast.Node.Index };
/// A node read under a set of settled comptime conditions (`assumed`).
const Settled = struct { key: Key, assumed: ?Assumptions.Id };
/// A set of settled assumptions, held once in `settled`.
const Assumptions = struct {
    held: []const Assumption,

    /// A set of `settled`, made only as it is appended or by counting them.
    const Id = enum(u32) { _ };
};
/// A `comptime` parameter's value on a path: a `bool`'s inside `if (wrapped)`'s branches or
/// after `if (wrapped) return ...;`, an enum's inside a `switch` prong naming one tag. Zig
/// analyses a branch of a comptime-known condition only in the instantiations that take it, so
/// what the path settles holds for everything read there.
pub const Assumption = struct {
    parameter: Decl,
    value: Known,

    fn eql(a: Assumption, b: Assumption) bool {
        if (!std.meta.eql(a.parameter, b.parameter) or std.meta.activeTag(a.value) != std.meta.activeTag(b.value)) return false;
        return switch (a.value) {
            .boolean => |value| value == b.value.boolean,
            .tag => |name| std.mem.eql(u8, name, b.value.tag),
        };
    }
};
pub const Known = union(enum) {
    boolean: bool,
    /// The enum literal's name, as written.
    tag: []const u8,
};
pub const Decl = struct { file: Project.FileId, index: Model.Declaration.Id };
pub const Container = struct {
    file: Project.FileId,
    scope: Model.Scope.Id,
    symbolic: bool = false,
    /// For a container a type function made: the call that made it, whose arguments its
    /// methods' results may name. Identity is `file` and `scope` alone.
    made_by: ?*const Made = null,
};
pub const Made = struct {
    function: Decl,
    file: Project.FileId,
    call: Ast.Node.Index,
    env: ?*const Env = null,
    assumed: ?Assumptions.Id = null,
    /// For a type function that returns another's call (`Owned(T, f)` returning
    /// `Owner(T, false, f)`): the call that made the outer one, whose bindings this call's
    /// arguments are read with.
    via: ?*const Made = null,
};
/// One call of a generic function being read: its parameters bound to the call's arguments,
/// in order (a method's receiver first). A type it returns, or a result type written in terms
/// of them, is read with these bindings.
pub const Env = struct {
    function: Decl,
    args: []const Value,
    depth: usize,
    /// Each argument's value as a condition, where it is a comptime-known `bool`.
    truths: []const ?bool = &.{},
};
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
/// file (Project.Input.absent), or it is a parameter no function of a reflected choice has
/// (`param_types[6]` of a table whose functions take at most six), so the code that needs it
/// is not compiled in this build.
/// `generic`: it depends on a type or `anytype` parameter that calls from outside the
/// project's reading bind (a consumer's, or a use other than a call), so each binding decides
/// it where it is made; what is read of it (its type information, its parts) stays so.
/// `std_internal`: std reads it from `root` or `builtin` (`root.std_options`, the target),
/// which no library's reading binds, so it is a type or value std computes for itself.
pub const Unknown = enum { invalid_front_end, unresolved, missing_mapping, computed_import, comptime_dependent, cycle, budget, unsupported, absent, generic, std_internal };
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
    /// A type Zig builds from a list of field types (`@Struct`, `@Union`, `@Tuple`), or a
    /// value of one: it holds what those types do, one or a choice among them. Its fields'
    /// names are computed as the program compiles.
    reified: Reified,
    /// A function type written in place (`fn (?*anyopaque, Io.Dir) void`, a vtable field's
    /// behind `*const`): its parameters' and result's types, as a declared function's are.
    fn_type: Key,

    pub fn known(self: Value) bool {
        return self != .unknown;
    }
};
pub const ResolveError = Model.InitError;
/// A type built from its fields' types, the type itself or a value of it as `container` and
/// `instance` are.
pub const Reified = struct { fields: *const Value, value: bool = false };

pub fn deinit(self: *Facts) void {
    self.cache.deinit(self.gpa);
    self.active.deinit(self.gpa);
    self.settled.deinit(self.gpa);
    if (self.copies) |*found| found.deinit(self.gpa);
    self.copier_names.deinit(self.gpa);
    self.bound_places.deinit(self.gpa);
    self.cast_sites.deinit(self.gpa);
    self.conditional_files.deinit(self.gpa);
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
    const key = @intFromPtr(library.modules.ptr);
    if (self.publications.get(key)) |found| return found;
    var entries: std.ArrayList(Entry) = .empty;
    var gaps: std.ArrayList(Gap) = .empty;
    var reached: FileSet = .empty;
    for (library.modules) |module| {
        for (self.project.imports, 0..) |mapping, index| {
            if (!std.mem.eql(u8, mapping.spelling, module.name)) continue;
            // Many files import one root; its members are found once.
            var repeated = false;
            for (self.project.imports[0..index]) |earlier| if (std.mem.eql(u8, earlier.spelling, module.name) and earlier.target == mapping.target) {
                repeated = true;
            };
            if (repeated) continue;
            try reached.put(self.gpa, @backingInt(mapping.target), {});
            for (module.members) |listed| switch (try self.published(mapping.target, listed.path)) {
                .found => |target| {
                    const role_value: u32 = @intCast(@backingInt(listed.role));
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
    try self.reach(&reached, .library);
    var files: std.ArrayList(Project.FileId) = .empty;
    var each = reached.keyIterator();
    while (each.next()) |file| try files.append(self.gpa, @fromBackingInt(file.*));
    const result = try self.gpa.create(Publication);
    result.* = .{ .entries = entries.items, .gaps = gaps.items, .files = files.items };
    try self.publications.put(self.gpa, key, result);
    return result;
}

/// A declaration literal called (`.init(...)`): the function its result location's container
/// declares. Any other enum literal's meaning is its result location's, which is not known here.
fn declarationLiteral(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const parent = self.project.at(file).model.parentOf(node) orelse return .{ .unknown = .comptime_dependent };
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return .{ .unknown = .comptime_dependent };
    if (call.ast.fn_expr != node) return .{ .unknown = .comptime_dependent };
    const container = (try self.resultContainer(file, parent)) orelse return .{ .unknown = .comptime_dependent };
    const found = self.member(container, try self.memberName(tree.tokenSlice(tree.nodeMainToken(node)))) orelse return .{ .unknown = .unsupported };
    return self.declaration(found);
}

/// Whether the file `root` publishes every member `module` requires: that module, not another
/// of its name.
pub fn publishes(self: *Facts, module: anytype, root: Project.FileId) ResolveError!bool {
    for (module.members) |listed| if (listed.required) switch (try self.published(root, listed.path)) {
        .found => {},
        .gap => return false,
    };
    return true;
}

const Found = union(enum) { found: Target, gap: Unknown };
/// Walks public namespaces from a module root, the way a program names the declaration.
fn published(self: *Facts, root: Project.FileId, path: []const u8) ResolveError!Found {
    var current: Value = .{ .container = self.rootOf(root) };
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
        if (!self.project.at(decl.file).model.declarations[@backingInt(decl.index)].public) return .{ .gap = .unresolved };
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
            for (found.entries) |entry| if (entry.target == .function and std.meta.eql(entry.target.function, decl)) return @as(Role, @fromBackingInt(@intCast(entry.role)));
            return null;
        },
        .container, .instance => |c| {
            for (found.entries) |entry| if (entry.target == .container and entry.target.container.file == c.file and entry.target.container.scope == c.scope) return @as(Role, @fromBackingInt(@intCast(entry.role)));
            return null;
        },
        else => return null,
    };
}

pub fn resolve(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    if (self.project.at(file).file.status != .parsed) return .{ .unknown = .invalid_front_end };
    const key: Settled = .{ .key = .{ .file = file, .node = node }, .assumed = self.assumed };
    if (self.cache.get(key)) |value| return value;
    if (self.active.count() >= 128) return .{ .unknown = .budget };
    if (self.remaining == 0) return .{ .unknown = .budget };
    self.remaining -= 1;
    if (self.active.contains(key)) return .{ .unknown = .cycle };
    try self.active.put(self.gpa, key, {});
    defer _ = self.active.remove(key);
    const outer = self.assumed;
    defer self.assumed = outer;
    self.assumed = try self.settle(file, node, outer);
    const value = try self.resolveInner(file, node);
    try self.cache.put(self.gpa, key, value);
    return value;
}

/// The set of assumptions in force at `node`: `outer` and what the path to `node` settles. A
/// path `outer` contradicts is not taken where `outer` holds; it keeps `outer`.
fn settle(self: *Facts, file: Project.FileId, node: Ast.Node.Index, outer: ?Assumptions.Id) ResolveError!?Assumptions.Id {
    if (!try self.hasConditions(file)) return outer;
    var found: std.ArrayList(Assumption) = .empty;
    try found.appendSlice(self.gpa, self.assumptions(outer));
    const before = found.items.len;
    if (!try self.pathFacts(file, node, &found)) return outer;
    if (found.items.len == before) return outer;
    return try self.intern(found.items);
}

/// Whether the path to `node` contradicts the assumptions in force: code an instantiation
/// that settles them does not analyse.
fn dead(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (self.assumed == null or !try self.hasConditions(file)) return false;
    var found: std.ArrayList(Assumption) = .empty;
    try found.appendSlice(self.gpa, self.assumptions(self.assumed));
    return !try self.pathFacts(file, node, &found);
}

fn assumptions(self: *const Facts, set: ?Assumptions.Id) []const Assumption {
    return if (set) |id| self.settled.items[@backingInt(id)].held else &.{};
}

/// The set holding exactly `items`, added if new.
fn intern(self: *Facts, items: []const Assumption) ResolveError!Assumptions.Id {
    for (self.settled.items, 0..) |set, index| {
        if (set.held.len != items.len) continue;
        for (items) |item| {
            for (set.held) |held| {
                if (held.eql(item)) break;
            } else break;
        } else return @fromBackingInt(@intCast(index));
    }
    try self.settled.append(self.gpa, .{ .held = try self.gpa.dupe(Assumption, items) });
    return @fromBackingInt(@intCast(self.settled.items.len - 1));
}

/// Adds to `found` what the path from the file's root to `node` settles: the branch of each
/// `if` on a comptime `bool` parameter that holds it, the prong of each `switch` on a comptime
/// enum parameter, and, in each enclosing block, every earlier `if (c) <exit>;` (the rest of
/// the block runs only where `c` is false). False when the path contradicts `found`.
fn pathFacts(self: *Facts, file: Project.FileId, node: Ast.Node.Index, found: *std.ArrayList(Assumption)) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    if (model.node_parents.len == 0) return true;
    var child = node;
    var up = model.parentOf(node);
    while (up) |parent| : ({
        child = parent;
        up = model.parentOf(parent);
    }) {
        if (tree.fullIf(parent)) |whole| if (whole.payload_token == null and whole.error_token == null) {
            if (child == whole.ast.then_expr and !try self.holds(file, whole.ast.cond_expr, true, found)) return false;
            if (whole.ast.else_expr.unwrap() == child and !try self.holds(file, whole.ast.cond_expr, false, found)) return false;
        };
        if (tree.fullSwitchCase(parent)) |case| if (case.ast.target_expr == child) if (model.parentOf(parent)) |at| if (tree.fullSwitch(at)) |whole| {
            if (self.switchParameter(file, whole.ast.condition)) |parameter| if (!try self.prong(tree, whole, case, parameter, found)) return false;
        };
        var buffer: [2]Ast.Node.Index = undefined;
        const statements = tree.blockStatements(&buffer, parent) orelse continue;
        for (statements) |statement| {
            if (statement == child) break;
            const whole = tree.fullIf(statement) orelse continue;
            if (whole.payload_token != null or whole.error_token != null) continue;
            const then_exits = completesNever(tree, whole.ast.then_expr);
            const else_exits = if (whole.ast.else_expr.unwrap()) |e| completesNever(tree, e) else false;
            if (then_exits == else_exits) continue;
            if (!try self.holds(file, whole.ast.cond_expr, else_exits, found)) return false;
        }
    }
    return true;
}

/// Records that the condition `node` is `value` where it names comptime `bool` parameters
/// (`wrapped`, `!wrapped`, `a and b` true, `a or b` false); other conditions settle nothing.
/// False when `found` already holds the opposite.
fn holds(self: *Facts, file: Project.FileId, node: Ast.Node.Index, value: bool, found: *std.ArrayList(Assumption)) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return self.holds(file, tree.nodeData(node).node_and_token[0], value, found),
        .@"comptime" => return self.holds(file, tree.nodeData(node).node, value, found),
        .bool_not => return self.holds(file, tree.nodeData(node).node, !value, found),
        .bool_and, .bool_or => {
            // Each operand is known only when the whole is: `a and b` true, `a or b` false.
            if ((tree.nodeTag(node) == .bool_and) != value) return true;
            const operands = tree.nodeData(node).node_and_node;
            return try self.holds(file, operands[0], value, found) and try self.holds(file, operands[1], value, found);
        },
        .identifier => {
            const parameter = self.conditionParameter(file, node) orelse return true;
            for (found.items) |held| if (std.meta.eql(held.parameter, parameter)) return held.value == .boolean and held.value.boolean == value;
            try found.append(self.gpa, .{ .parameter = parameter, .value = .{ .boolean = value } });
            return true;
        },
        else => return true,
    }
}

/// Records that a `switch` prong on a comptime parameter is taken: the parameter is the tag the
/// prong's one item names. False when `found` holds a tag the prong does not take: none of its
/// items, or for `else`, one a case names.
fn prong(self: *Facts, tree: *const Ast, whole: Ast.full.Switch, case: Ast.full.SwitchCase, parameter: Decl, found: *std.ArrayList(Assumption)) ResolveError!bool {
    for (found.items) |held| if (std.meta.eql(held.parameter, parameter)) {
        if (held.value != .tag) return true;
        if (case.ast.values.len == 0) {
            for (whole.ast.cases) |other| for (tree.fullSwitchCase(other).?.ast.values) |item| if (namesTag(tree, item, held.value.tag)) return false;
            return true;
        }
        for (case.ast.values) |item| if (namesTag(tree, item, held.value.tag)) return true;
        return false;
    };
    if (case.ast.values.len == 1 and tree.nodeTag(case.ast.values[0]) == .enum_literal) try found.append(self.gpa, .{ .parameter = parameter, .value = .{ .tag = tree.tokenSlice(tree.nodeMainToken(case.ast.values[0])) } });
    return true;
}

fn namesTag(tree: *const Ast, item: Ast.Node.Index, tag: []const u8) bool {
    return tree.nodeTag(item) == .enum_literal and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(item)), tag);
}

/// Whether the function around `node` branches on a comptime `bool` parameter, or switches on a
/// comptime enum one, anywhere in its body: its paths then differ between the instantiations
/// that bind it.
pub fn branchesOnCondition(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (!try self.hasConditions(file)) return false;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var up = model.parentOf(node);
    const function = while (up) |parent| : (up = model.parentOf(parent)) {
        if (tree.nodeTag(parent) == .fn_decl) break parent;
    } else return false;
    const first = tree.firstToken(function);
    const last = tree.lastToken(function);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const branch: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(branch);
        if (at < first or at > last) continue;
        switch (tag) {
            .@"if", .if_simple => if (self.namesCondition(file, tree.fullIf(branch).?.ast.cond_expr, 0)) return true,
            .@"switch", .switch_comma => if (self.switchParameter(file, tree.fullSwitch(branch).?.ast.condition) != null) return true,
            else => {},
        }
    }
    return false;
}

fn namesCondition(self: *const Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) bool {
    if (depth == 16) return false;
    const tree = &self.project.at(file).file.tree;
    return switch (tree.nodeTag(node)) {
        .identifier => self.conditionParameter(file, node) != null,
        .grouped_expression => self.namesCondition(file, tree.nodeData(node).node_and_token[0], depth + 1),
        .@"comptime", .bool_not => self.namesCondition(file, tree.nodeData(node).node, depth + 1),
        .bool_and, .bool_or => self.namesCondition(file, tree.nodeData(node).node_and_node[0], depth + 1) or self.namesCondition(file, tree.nodeData(node).node_and_node[1], depth + 1),
        else => false,
    };
}

/// A local a generic function initialises by copying a value its type parameter at `position`
/// types (`var result = value;` of `value: T`), or its `anytype` parameter at `position`
/// (`var local = args;`), there or in a function it passes the parameter on to (as is, or a
/// part of it its type information gives). Or a local it initialises by calling a function of
/// its type parameter at `position` (`var h = Hash.init(.{});`): what the call gives is the
/// binding's, an owner where the binding is one. What a call passes on may be the parameter
/// itself or a value of it, or something else read from it (what calling it returns, what it
/// points to): then `source` is that expression, read with the binding's arguments through the
/// calls of `path`, each in the function before it, the first in the generic the copy is of.
/// Each route to a source is its own copy, up to `routes`; past them the copy is `crowded`,
/// and a binding of it is not read.
pub const ParameterCopy = struct {
    position: usize,
    site: Key,
    kind: enum { copy, made, cast } = .copy,
    source: ?Key = null,
    path: []const Key = &.{},
    crowded: bool = false,
};

/// How many routes through generics to one source are read for each parameter and copy.
const routes = 4;

/// The copies `function` makes of its generic parameters' values. Found once for every function
/// outside std: a copy where it is written, then through calls that pass a parameter on, until
/// nothing more is found.
pub fn parameterCopies(self: *Facts, function: Decl) ResolveError![]const ParameterCopy {
    if (self.copies == null) try self.findCopies();
    return self.copies.?.get(function) orelse &.{};
}

fn findCopies(self: *Facts) ResolveError!void {
    var found: std.AutoHashMapUnmanaged(Decl, []const ParameterCopy) = .empty;
    self.copies = found;
    const std_files = &(try self.outside()).std_files;
    var functions: std.ArrayList(Decl) = .empty;
    for (self.project.sources) |*source| {
        const file = &source.file;
        const model = &source.model;
        const id = source.id;
        if (file.status != .parsed or std_files.contains(@backingInt(id))) continue;
        for (model.declarations, 0..) |d, i| {
            if (d.kind != .function) continue;
            const decl: Decl = .{ .file = id, .index = @fromBackingInt(@intCast(i)) };
            if (self.syntaxOf(id).nodeTag(self.scopeNode(decl)) != .fn_decl) continue;
            if (!self.hasGenericParameter(decl)) continue;
            try functions.append(self.gpa, decl);
            var direct: std.ArrayList(ParameterCopy) = .empty;
            try self.directCopies(decl, &direct);
            if (direct.items.len != 0) try found.put(self.gpa, decl, direct.items);
        }
    }
    // Through calls that pass a parameter on, to a fixed point: a function whose copies grow
    // is read again in each generic that calls it. Copies only grow, each route at most once
    // and at most `routes` routes to a source, so it ends.
    var calls: std.AutoHashMapUnmanaged(Decl, []const Passing) = .empty;
    var callers: std.AutoHashMapUnmanaged(Decl, std.ArrayList(Decl)) = .empty;
    for (functions.items) |decl| {
        const passing = try self.passings(decl);
        try calls.put(self.gpa, decl, passing);
        for (passing) |each| {
            const entry = try callers.getOrPut(self.gpa, each.target);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.gpa, decl);
        }
    }
    var queue: std.ArrayList(Decl) = .empty;
    var queued: std.AutoHashMapUnmanaged(Decl, void) = .empty;
    for (functions.items) |decl| {
        try queue.append(self.gpa, decl);
        try queued.put(self.gpa, decl, {});
    }
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const decl = queue.items[next];
        _ = queued.remove(decl);
        var more: std.ArrayList(ParameterCopy) = .empty;
        // Each held copy its own, as a route found crowded is marked in place.
        for (found.get(decl) orelse &.{}) |copy| try more.append(self.gpa, copy);
        self.copies = found;
        if (!try self.passedCopies(decl, calls.get(decl).?, &more)) continue; // unreachable: every function's calls are read above
        try found.put(self.gpa, decl, more.items);
        for (if (callers.get(decl)) |list| list.items else &.{}) |caller| {
            if ((try queued.getOrPut(self.gpa, caller)).found_existing) continue;
            try queue.append(self.gpa, caller);
        }
    }
    self.copies = found;
    var it = found.keyIterator();
    while (it.next()) |decl| try self.copier_names.put(self.gpa, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name, {});
}

/// Whether some function named `name` copies a generic parameter's values.
pub fn mayCopy(self: *Facts, name: []const u8) ResolveError!bool {
    if (self.copies == null) try self.findCopies();
    return self.copier_names.contains(name);
}

fn syntaxOf(self: *const Facts, file: Project.FileId) *const Ast {
    return &self.project.at(file).file.tree;
}

/// Whether `spelling` is Zig's own `root` or `builtin` imported by one of std's files: what
/// std computes from the program it is in and the target it is built for.
fn zigOwn(self: *Facts, file: Project.FileId, spelling: []const u8) ResolveError!bool {
    if (!std.mem.eql(u8, spelling, "root") and !std.mem.eql(u8, spelling, "builtin")) return false;
    return (try self.outside()).std_files.contains(@backingInt(file));
}

/// Whether `file` is one of std's: a file std's import reaches.
pub fn standard(self: *Facts, file: Project.FileId) ResolveError!bool {
    return (try self.outside()).std_files.contains(@backingInt(file));
}

/// Whether `file` is the program's: every loaded file but those std's import reaches and those
/// a known library's module roots reach (`known`), which the analyses know by their
/// declarations. A file of the package the run did not select and a dependency's are the
/// program's as much as a selected one: what they do runs as its own, so a scan of "every use
/// in the program" reads them, and one that stops at a selection decides nothing past it.
pub fn program(self: *Facts, file: Project.FileId) ResolveError!bool {
    return (try self.outside()).own(file);
}

/// The files that are not the program's, found once: std's and the known libraries'.
pub fn outside(self: *Facts) ResolveError!*const Outside {
    const found = try self.memo(Outside);
    if (found.built) return found;
    found.built = true;
    found.project = self.project;
    for (self.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) try found.std_files.put(self.gpa, @backingInt(mapping.target), {});
    try self.reach(&found.std_files, .standard);
    for (self.known) |name| for (self.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, name)) {
        try found.known_files.put(self.gpa, @backingInt(mapping.target), {});
    };
    try self.reach(&found.known_files, .library);
    return found;
}
pub const Outside = struct {
    /// The files std's import reaches.
    std_files: FileSet = .empty,
    /// The files a known library's module roots reach, std's aside.
    known_files: FileSet = .empty,
    project: *const Project = undefined,
    built: bool = false,

    /// Whether `file` is the program's. A file the run selected is: what is linted is the
    /// program, a library's own sources among them when the run is the library's.
    pub fn own(self: *const Outside, file: Project.FileId) bool {
        if (self.project.at(file).input.selected) return true;
        return !self.std_files.contains(@backingInt(file)) and !self.known_files.contains(@backingInt(file));
    }
};

/// Grows `files` to every file their imports reach. std's reach follows every import of its
/// own; a library's stops at std, builtin and root, which are not its files.
fn reach(self: *Facts, files: *FileSet, from: enum { standard, library }) ResolveError!void {
    var growing = true;
    while (growing) {
        growing = false;
        for (self.project.imports) |mapping| {
            if (!files.contains(@backingInt(mapping.from)) or files.contains(@backingInt(mapping.target))) continue;
            if (from == .library and (std.mem.eql(u8, mapping.spelling, "std") or std.mem.eql(u8, mapping.spelling, "builtin") or std.mem.eql(u8, mapping.spelling, "root"))) continue;
            try files.put(self.gpa, @backingInt(mapping.target), {});
            growing = true;
        }
    }
}
/// Files by their ids' numbers.
pub const FileSet = std.AutoHashMapUnmanaged(u32, void);

/// The position of each parameter of `function` that takes a type or `anytype`, by its
/// declaration's index; null for any other parameter.
fn genericPosition(self: *const Facts, function: Decl, parameter: Model.Declaration.Id) ?usize {
    const model = &self.project.at(function.file).model;
    const record = model.declarations[@backingInt(parameter)];
    if (record.kind != .parameter or model.scopes[@backingInt(record.scope)].node != self.scopeNode(function)) return null;
    const t = self.syntaxOf(function.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = t.fullFnProto(&fn_buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(t);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token != record.token) continue;
        if (param.anytype_ellipsis3 != null) return position;
        const type_expr = param.type_expr orelse return null;
        return if (typeKeyword(t, type_expr)) position else null;
    }
    return null;
}

/// The position of `function`'s parameter named at `token`, when it is `anytype`.
pub fn anytypeAt(self: *const Facts, function: Decl, token: Ast.TokenIndex) ?usize {
    const t = self.syntaxOf(function.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = t.fullFnProto(&fn_buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(t);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) {
        if (param.name_token == token) return if (param.anytype_ellipsis3 != null) position else null;
    }
    return null;
}

fn hasGenericParameter(self: *const Facts, function: Decl) bool {
    const t = self.syntaxOf(function.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = t.fullFnProto(&fn_buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    var it = proto.iterate(t);
    while (it.next()) |param| {
        if (param.anytype_ellipsis3 != null) return true;
        if (param.type_expr) |type_expr| if (typeKeyword(t, type_expr)) return true;
    }
    return false;
}

/// The generic parameter whose value `value` is: a parameter of `function` declared `T` of a
/// type parameter, or an `anytype` parameter, its own argument's value. A `comptime` one's
/// value is known as the program compiles and holds nothing at run time: none.
fn valueOfParameter(self: *const Facts, function: Decl, value: Model.Declaration.Id) ?usize {
    const model = &self.project.at(function.file).model;
    const record = model.declarations[@backingInt(value)];
    if (record.kind != .parameter or model.scopes[@backingInt(record.scope)].node != self.scopeNode(function)) return null;
    const t = self.syntaxOf(function.file);
    if (record.token > 0 and t.tokenTag(record.token - 1) == .keyword_comptime) return null;
    if (self.anytypeAt(function, record.token)) |position| return position;
    if (t.nodeTag(record.node) != .identifier) return null;
    const named = (model.reference(record.node) orelse return null).declaration orelse return null;
    return self.genericPosition(function, named);
}

/// `const x = v;` in `function`'s own body, `v` a value of a generic parameter.
fn directCopies(self: *Facts, function: Decl, out: *std.ArrayList(ParameterCopy)) ResolveError!void {
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const whole = self.scopeNode(function);
    for (model.declarations) |d| {
        // A local of the body: a declaration of a container it returns is comptime.
        if (d.kind != .variable or model.scopes[@backingInt(d.scope)].kind != .block or !self.enclosed(function.file, d.scope, whole)) continue;
        const v = t.fullVarDecl(d.node) orelse continue;
        if (v.comptime_token != null) continue;
        // A `comptime` block runs as the program compiles: its locals copy nothing at run time.
        if (inComptime(t, model, d.node)) continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        if (self.madeByParameter(function.file, init)) |position| {
            try out.append(self.gpa, .{ .position = position, .site = .{ .file = function.file, .node = d.node }, .kind = .made });
            continue;
        }
        if (t.nodeTag(init) == .identifier) {
            const named = (model.reference(init) orelse continue).declaration orelse continue;
            const position = self.valueOfParameter(function, named) orelse continue;
            try out.append(self.gpa, .{ .position = position, .site = .{ .file = function.file, .node = d.node } });
            continue;
        }
        // A value chosen or wrapped (`out catch |e| return e`, `if (c) v.a else v.b`): each
        // place it reads that a generic parameter gives, read with the binding's arguments.
        // Into a type written apart from the parameters (`const kind: Kind = ...`) it is the
        // same copy in every binding, decided where it is written.
        if (v.ast.type_node.unwrap()) |declared| if (self.derivedParameter(function, declared, 0) == null) continue;
        const parts = try self.copiedParts(function.file, init);
        for (parts.places) |place| {
            const position = self.runtimeParameter(function, place, 0) orelse continue;
            // A place whose value resolves where it is written is the same copy in every
            // binding, decided there; only what the binding settles is read with it.
            if (try self.resolve(function.file, place) != .unknown) continue;
            const site: Key = .{ .file = function.file, .node = d.node };
            // The parameter itself is its argument, read as written where it is bound.
            const itself = t.nodeTag(place) == .identifier and if (model.reference(place)) |ref| if (ref.declaration) |named| self.valueOfParameter(function, named) != null else false else false;
            try out.append(self.gpa, .{ .position = position, .site = site, .source = if (itself) null else .{ .file = function.file, .node = place } });
            try self.bound_places.put(self.gpa, .{ .site = site, .place = place }, {});
        }
    }
    try self.scalarCasts(function, out);
}

/// The integers the language makes into a type, or reads out of a value, by the type of
/// `function`'s generic parameter: `@enumFromInt` and `@fromBackingInt` into a type its result
/// place writes in terms of one (`@as(@TypeOf(library).Role, ...)`), `@intFromEnum` and
/// `@backingInt` of a value one gives. Each is the binding's: its type is the bound one's
/// (`kind = .cast`, `source` the type written, or the value read).
fn scalarCasts(self: *Facts, function: Decl, out: *std.ArrayList(ParameterCopy)) ResolveError!void {
    const t = self.syntaxOf(function.file);
    const whole = self.scopeNode(function);
    const first = t.firstToken(whole);
    const last = t.lastToken(whole);
    for (t.nodes.items(.tag), 0..) |tag, i| {
        switch (tag) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(node);
        if (at < first or at > last) continue;
        const name = t.tokenSlice(at);
        var buffer: [2]Ast.Node.Index = undefined;
        const args = builtinArgs(t, node, &buffer);
        const source: Ast.Node.Index = if (std.mem.eql(u8, name, "@enumFromInt") or std.mem.eql(u8, name, "@fromBackingInt"))
            self.writtenType(function.file, node, 0) orelse continue
        else if ((std.mem.eql(u8, name, "@intFromEnum") or std.mem.eql(u8, name, "@backingInt")) and args.len == 1)
            args[0]
        else
            continue;
        const position = self.derivedParameter(function, source, 0) orelse continue;
        const site: Key = .{ .file = function.file, .node = node };
        try out.append(self.gpa, .{ .position = position, .site = site, .kind = .cast, .source = .{ .file = function.file, .node = source } });
        try self.cast_sites.put(self.gpa, site, {});
    }
}

/// The type written for the place `node`'s value goes to: `@as`'s, a declaration's, the
/// function's result for a `return`, through a grouping, `try`, either side of `orelse` or
/// `catch`, a branch or a prong. Null where none is written there.
fn writtenType(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize) ?Ast.Node.Index {
    if (depth == 16) return null;
    const t = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    const parent = model.parentOf(node) orelse return null;
    if (t.fullVarDecl(parent)) |variable| return if (variable.ast.init_node.unwrap() == node) variable.ast.type_node.unwrap() else null;
    switch (t.nodeTag(parent)) {
        .grouped_expression, .@"try", .@"orelse", .@"catch", .@"if", .if_simple, .@"switch", .switch_comma, .switch_case_one, .switch_case_inline_one, .switch_case, .switch_case_inline => return self.writtenType(file, parent, depth + 1),
        .@"return" => {
            var at: ?Ast.Node.Index = model.parentOf(parent);
            while (at) |candidate| : (at = model.parentOf(candidate)) {
                if (t.nodeTag(candidate) != .fn_decl) continue;
                var fn_buffer: [1]Ast.Node.Index = undefined;
                return (t.fullFnProto(&fn_buffer, t.nodeData(candidate).node_and_node[0]) orelse return null).ast.return_type.unwrap();
            }
            return null;
        },
        .builtin_call_two, .builtin_call_two_comma => {
            if (!std.mem.eql(u8, t.tokenSlice(t.nodeMainToken(parent)), "@as")) return null;
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(t, parent, &buffer);
            return if (args.len == 2 and args[1] == node) args[0] else null;
        },
        else => return null,
    }
}

/// Whether the builtin `node` makes or reads an integer by the type of a generic parameter,
/// which each binding of the generic decides (`scalarCasts`).
pub fn castAtBinding(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!bool {
    if (self.copies == null) try self.findCopies();
    return self.cast_sites.contains(.{ .file = file, .node = node });
}

/// What a copy of the value written `node` copies: the places it reads (a name, a field,
/// `@field`, what a pointer points at, an element, an optional's payload), followed through
/// every way a value is chosen or wrapped (a branch, a prong, a `break`, `orelse`, `catch`,
/// `try`, `@as`, `@bitCast`, `@unionInit`, `++`, a literal's parts); and the values of other
/// shapes, decided by their type. A call's result, a literal of plain data, a pointer and a
/// branch that leaves are no copy of a place. `deep` is a value nested past what is followed.
pub const Copied = struct { places: []const Ast.Node.Index, rest: []const Ast.Node.Index, deep: ?Ast.Node.Index };

pub fn copiedParts(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Copied {
    var places: std.ArrayList(Ast.Node.Index) = .empty;
    var rest: std.ArrayList(Ast.Node.Index) = .empty;
    var deep: ?Ast.Node.Index = null;
    try self.copiedWalk(file, node, 0, &places, &rest, &deep);
    return .{ .places = places.items, .rest = rest.items, .deep = deep };
}

fn copiedWalk(self: *Facts, file: Project.FileId, node: Ast.Node.Index, depth: usize, places: *std.ArrayList(Ast.Node.Index), rest: *std.ArrayList(Ast.Node.Index), deep: *?Ast.Node.Index) ResolveError!void {
    if (depth == 64) {
        if (deep.* == null) deep.* = node;
        return;
    }
    const t = self.syntaxOf(file);
    switch (t.nodeTag(node)) {
        .identifier, .field_access, .deref, .array_access, .unwrap_optional => return places.append(self.gpa, node),
        .grouped_expression => return self.copiedWalk(file, t.nodeData(node).node_and_token[0], depth + 1, places, rest, deep),
        .@"try", .@"comptime", .@"nosuspend" => return self.copiedWalk(file, t.nodeData(node).node, depth + 1, places, rest, deep),
        .@"orelse", .@"catch", .array_cat => {
            const sides = t.nodeData(node).node_and_node;
            try self.copiedWalk(file, sides[0], depth + 1, places, rest, deep);
            return self.copiedWalk(file, sides[1], depth + 1, places, rest, deep);
        },
        .@"if", .if_simple => {
            const branch = t.fullIf(node).?; // unreachable: the tag is an `if`'s
            try self.copiedWalk(file, branch.ast.then_expr, depth + 1, places, rest, deep);
            if (branch.ast.else_expr.unwrap()) |otherwise| try self.copiedWalk(file, otherwise, depth + 1, places, rest, deep);
            return;
        },
        .@"switch", .switch_comma => {
            for (t.fullSwitch(node).?.ast.cases) |case| try self.copiedWalk(file, t.fullSwitchCase(case).?.ast.target_expr, depth + 1, places, rest, deep); // unreachable: the tag is a switch's, its cases are cases
            return;
        },
        .block, .block_semicolon, .block_two, .block_two_semicolon => {
            // A block with no label gives `void`.
            const brace = t.nodeMainToken(node);
            if (brace < 2 or t.tokenTag(brace - 1) != .colon or t.tokenTag(brace - 2) != .identifier) return;
            for (try self.blockBreaks(file, node, t.tokenSlice(brace - 2))) |value| try self.copiedWalk(file, value, depth + 1, places, rest, deep);
            return;
        },
        // A loop's value: each `break` out of it, and its `else`.
        .@"for", .for_simple, .@"while", .while_simple, .while_cont => {
            const start = t.firstToken(node);
            const label: ?[]const u8 = if (start >= 2 and t.tokenTag(start) != .identifier and t.tokenTag(start - 1) == .colon and t.tokenTag(start - 2) == .identifier) t.tokenSlice(start - 2) else null;
            for (try self.loopBreaks(file, node, label)) |value| try self.copiedWalk(file, value, depth + 1, places, rest, deep);
            const otherwise = if (t.fullFor(node)) |loop| loop.ast.else_expr else t.fullWhile(node).?.ast.else_expr; // unreachable: the tag is a loop's
            if (otherwise.unwrap()) |value| try self.copiedWalk(file, value, depth + 1, places, rest, deep);
            return;
        },
        // What a call returns is the callee's, its `return` checked there.
        .call_one, .call_one_comma, .call, .call_comma => return,
        // No value: control leaves.
        .@"return", .@"break", .@"continue", .unreachable_literal => return,
        // A pointer, or a slice of what it points at: an alias.
        .address_of, .slice, .slice_open, .slice_sentinel => return,
        // A number, text, an error, or an enum's tag; or a declaration literal (`.empty`),
        // which names a container's `const`, known as the program compiles.
        .number_literal, .char_literal, .string_literal, .multiline_string_literal, .error_value, .enum_literal => return,
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const name = t.tokenSlice(t.nodeMainToken(node));
            var buffer: [2]Ast.Node.Index = undefined;
            const args = builtinArgs(t, node, &buffer);
            if (std.mem.eql(u8, name, "@field")) return places.append(self.gpa, node);
            if (args.len != 0 and (std.mem.eql(u8, name, "@as") or std.mem.eql(u8, name, "@bitCast"))) return self.copiedWalk(file, args[args.len - 1], depth + 1, places, rest, deep);
            if (args.len == 3 and std.mem.eql(u8, name, "@unionInit")) return self.copiedWalk(file, args[2], depth + 1, places, rest, deep);
            // Every other builtin gives no owner's copy: a number, an enum, a pointer, a
            // vector, a type, text, an error or nothing (`@intCast`, `@fromBackingInt`,
            // `@ptrCast`, `@splat`, `@This`, `@tagName`, `@memcpy`); `@call` calls.
            return;
        },
        else => {
            var buffer: [2]Ast.Node.Index = undefined;
            if (t.fullStructInit(&buffer, node)) |literal| {
                for (literal.ast.fields) |field| try self.copiedWalk(file, field, depth + 1, places, rest, deep);
                return;
            }
            if (t.fullArrayInit(&buffer, node)) |literal| {
                for (literal.ast.elements) |item| try self.copiedWalk(file, item, depth + 1, places, rest, deep);
                return;
            }
            return rest.append(self.gpa, node);
        },
    }
}

/// The values each `break :label` out of the labeled block `node` gives (Zig refuses a label
/// that shadows another, so each names this block).
pub fn blockBreaks(self: *Facts, file: Project.FileId, node: Ast.Node.Index, label: []const u8) ResolveError![]const Ast.Node.Index {
    const t = self.syntaxOf(file);
    var found: std.ArrayList(Ast.Node.Index) = .empty;
    const first = t.firstToken(node);
    const last = t.lastToken(node);
    for (t.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const brk: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(brk);
        if (at < first or at > last) continue;
        const target, const value = t.nodeData(brk).opt_token_and_opt_node;
        if (!std.mem.eql(u8, t.tokenSlice(target.unwrap() orelse continue), label)) continue;
        try found.append(self.gpa, value.unwrap() orelse continue);
    }
    return found.items;
}

/// The values each `break` out of the loop `node` gives: one naming its `label`, or one with
/// none whose nearest loop it is.
pub fn loopBreaks(self: *Facts, file: Project.FileId, node: Ast.Node.Index, label: ?[]const u8) ResolveError![]const Ast.Node.Index {
    const t = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    var found: std.ArrayList(Ast.Node.Index) = .empty;
    const first = t.firstToken(node);
    const last = t.lastToken(node);
    for (t.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const brk: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = t.nodeMainToken(brk);
        if (at < first or at > last) continue;
        const target, const value = t.nodeData(brk).opt_token_and_opt_node;
        if (target.unwrap()) |name| {
            if (label == null or !std.mem.eql(u8, t.tokenSlice(name), label.?)) continue;
        } else {
            // The nearest loop the `break` is in.
            var up = model.parentOf(brk);
            const nearest = while (up) |parent| : (up = model.parentOf(parent)) {
                if (t.fullFor(parent) != null or t.fullWhile(parent) != null) break parent;
            } else continue;
            if (nearest != node) continue;
        }
        try found.append(self.gpa, value.unwrap() orelse continue);
    }
    return found.items;
}

/// Whether the declaration `site` is a copy a generic function makes of its parameters'
/// values that its bindings decide (`parameterCopies`), reading `place`.
pub fn boundAtBinding(self: *Facts, file: Project.FileId, site: Ast.Node.Index, place: Ast.Node.Index) ResolveError!bool {
    if (self.copies == null) try self.findCopies();
    return self.bound_places.contains(.{ .site = .{ .file = file, .node = site }, .place = place });
}

/// The position of the type parameter whose function `value` calls (`T.init(...)`, through
/// `try` or `catch`), a parameter of the function the call is in declared `comptime T: type`.
pub fn madeByParameter(self: *const Facts, file: Project.FileId, value: Ast.Node.Index) ?usize {
    const t = self.syntaxOf(file);
    const made = switch (t.nodeTag(value)) {
        .@"try" => t.nodeData(value).node,
        .@"catch" => t.nodeData(value).node_and_node[0],
        else => value,
    };
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = t.fullCall(&call_buffer, made) orelse return null;
    if (t.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver = t.nodeData(call.ast.fn_expr).node_and_token[0];
    if (t.nodeTag(receiver) != .identifier) return null;
    const model = &self.project.at(file).model;
    const index = (model.reference(receiver) orelse return null).declaration orelse return null;
    const function = self.functionOf(.{ .file = file, .index = index }) orelse return null;
    if (self.anytypeAt(function, model.declarations[@backingInt(index)].token) != null) return null;
    return self.genericPosition(function, index);
}

/// A call in a generic's body passing one of its generic parameters on, or a part of one, and
/// the function it calls.
const Passing = struct { node: Ast.Node.Index, target: Decl };

/// The calls in `function`'s body that pass a generic parameter on, or a part of one.
fn passings(self: *Facts, function: Decl) ResolveError![]const Passing {
    const t = self.syntaxOf(function.file);
    const whole = self.scopeNode(function);
    const first = t.firstToken(whole);
    const last = t.lastToken(whole);
    var found: std.ArrayList(Passing) = .empty;
    for (t.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = t.fullCall(&call_buffer, node) orelse continue;
        const at = t.nodeMainToken(node);
        if (at < first or at > last) continue;
        var passes = false;
        for (call.ast.params) |arg| if (self.derivedParameter(function, arg, 0) != null) {
            passes = true;
        };
        if (!passes) continue;
        const callee = (try self.definition(function.file, call.ast.fn_expr)) orelse continue;
        const target = (try self.origin(callee)) orelse continue;
        if (std.meta.eql(target, function)) continue;
        try found.append(self.gpa, .{ .node = node, .target = target });
    }
    return found.items;
}

/// Each call of `passing` passing a generic parameter on where the callee copies the parameter
/// it takes: `function` copies its own, added to `out`. Whether `out` grew, or a route in it
/// was found crowded.
fn passedCopies(self: *Facts, function: Decl, passing: []const Passing, out: *std.ArrayList(ParameterCopy)) ResolveError!bool {
    const t = self.syntaxOf(function.file);
    var changed = false;
    for (passing) |each| {
        const node = each.node;
        const target = each.target;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = t.fullCall(&call_buffer, node).?; // unreachable: a passing is a call
        const theirs = self.copies.?.get(target) orelse continue;
        const receiver: usize = if (self.methodCall(function.file, call, target)) 1 else 0;
        for (theirs) |copy| {
            if (copy.position < receiver or copy.position - receiver >= call.ast.params.len) continue;
            const argument = call.ast.params[copy.position - receiver];
            const mine = self.derivedParameter(function, argument, 0) orelse continue;
            // A path through this call again is a cycle of generics passing it round.
            if (copy.source != null and onPath(copy.path, .{ .file = function.file, .node = node })) continue;
            // A route past those read stays past them for each caller.
            const passed: ParameterCopy = if (copy.source) |source| .{
                .position = mine,
                .site = copy.site,
                .kind = copy.kind,
                .source = source,
                .path = try std.mem.concat(self.gpa, Key, &.{ &.{.{ .file = function.file, .node = node }}, copy.path }),
                .crowded = copy.crowded,
            } else if (self.readThrough(function, argument, 0))
                .{ .position = mine, .site = copy.site, .kind = copy.kind, .source = .{ .file = function.file, .node = argument }, .crowded = copy.crowded }
            else
                .{ .position = mine, .site = copy.site, .kind = copy.kind, .crowded = copy.crowded };
            var seen: usize = 0;
            for (out.items) |*held| {
                if (held.position != passed.position or !std.meta.eql(held.site, passed.site) or !std.meta.eql(held.source, passed.source)) continue;
                if (samePath(held.path, passed.path)) {
                    if (passed.crowded and !held.crowded) {
                        held.crowded = true;
                        changed = true;
                    }
                    break;
                }
                seen += 1;
                if (seen == routes) {
                    if (!held.crowded) changed = true;
                    held.crowded = true;
                    break;
                }
            } else {
                try out.append(self.gpa, passed);
                changed = true;
            }
        }
    }
    return changed;
}

fn onPath(path: []const Key, step: Key) bool {
    for (path) |each| if (std.meta.eql(each, step)) return true;
    return false;
}

fn samePath(a: []const Key, b: []const Key) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}

/// Whether `node` reads from a generic parameter of `function` what the parameter does not
/// hold: what calling it, or a method of it, returns, or what it points to. What it holds (a
/// field, an element, the payload of an optional or an error union) is the binding's argument's,
/// read whole where it is bound.
fn readThrough(self: *const Facts, function: Decl, node: Ast.Node.Index, depth: usize) bool {
    if (depth == 8) return false;
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const last = t.lastToken(node);
    for (t.firstToken(node)..last + 1) |raw| {
        const token: Ast.TokenIndex = @intCast(raw);
        if (t.tokenTag(token) != .identifier) continue;
        const index = self.lexical(function.file, model.scopeOf(token), t.tokenSlice(token)) orelse continue;
        const record = model.declarations[@backingInt(index)];
        if (self.genericPosition(function, index) != null or self.valueOfParameter(function, index) != null) {
            // `p(...)`, `p.f(...)`, `p.*`, `p.f.*`.
            var next = token + 1;
            while (next + 1 <= last and t.tokenTag(next) == .period and t.tokenTag(next + 1) == .identifier) next += 2;
            if (next <= last and (t.tokenTag(next) == .l_paren or t.tokenTag(next) == .period_asterisk)) return true;
            continue;
        }
        if (record.kind != .variable or !self.enclosed(function.file, record.scope, self.scopeNode(function))) continue;
        const init = (t.fullVarDecl(record.node) orelse continue).ast.init_node.unwrap() orelse continue;
        if (init != node and self.readThrough(function, init, depth + 1)) return true;
    }
    return false;
}

/// What a copy `function` makes holds at the binding `call` in `file`: the binding's argument
/// read through the copy's `path` to its `source`, each call's arguments read with the bindings
/// of the one before. `receiver` is whether the call passes a value as the first parameter.
pub fn boundCopy(self: *Facts, file: Project.FileId, call: Ast.full.Call, receiver: bool, function: Decl, copy: ParameterCopy) ResolveError!Value {
    const source = copy.source.?;
    const tree = self.syntaxOf(file);
    var args: std.ArrayList(Value) = .empty;
    if (receiver) try args.append(self.gpa, try self.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0]));
    for (call.ast.params) |arg| try args.append(self.gpa, try self.resolve(file, arg));
    var env = try self.gpa.create(Env);
    env.* = .{ .function = function, .args = args.items, .depth = 0 };
    for (copy.path) |step| {
        const step_tree = self.syntaxOf(step.file);
        var step_buffer: [1]Ast.Node.Index = undefined;
        const inner = step_tree.fullCall(&step_buffer, step.node) orelse return .{ .unknown = .unsupported };
        const callee = (try self.definition(step.file, inner.ast.fn_expr)) orelse return .{ .unknown = .unresolved };
        const target = (try self.origin(callee)) orelse return .{ .unknown = .unresolved };
        var inner_args: std.ArrayList(Value) = .empty;
        if (self.methodCall(step.file, inner, target)) try inner_args.append(self.gpa, try self.resolveIn(env, step.file, step_tree.nodeData(inner.ast.fn_expr).node_and_token[0]));
        for (inner.ast.params) |arg| try inner_args.append(self.gpa, try self.resolveIn(env, step.file, arg));
        const next = try self.gpa.create(Env);
        next.* = .{ .function = target, .args = inner_args.items, .depth = env.depth +| 1 };
        env = next;
    }
    return self.resolveIn(env, source.file, source.node);
}

/// Whether `node`, an identifier, names a `comptime` parameter.
pub fn comptimeParameter(self: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const t = self.syntaxOf(file);
    if (t.nodeTag(node) != .identifier) return false;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return false).declaration orelse return false;
    const record = model.declarations[@backingInt(index)];
    return record.kind == .parameter and record.token > 0 and t.tokenTag(record.token - 1) == .keyword_comptime;
}

/// Whether `node`, an identifier, names a value of a type parameter of its function (`value`
/// of `value: T`): a copy of it is each binding's.
pub fn parameterValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const model = &self.project.at(file).model;
    if (self.syntaxOf(file).nodeTag(node) != .identifier) return false;
    const index = (model.reference(node) orelse return false).declaration orelse return false;
    const function = self.functionOf(.{ .file = file, .index = index }) orelse return false;
    return self.valueOfParameter(function, index) != null;
}

/// Whether `node`, written in a generic function, is or is a part of one of its generic
/// parameters: a binding passed on, which the binding of that parameter decides.
pub fn fromParameter(self: *Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const t = self.syntaxOf(file);
    const model = &self.project.at(file).model;
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) {
        if (t.nodeTag(parent) != .fn_decl) continue;
        for (model.declarations, 0..) |d, i| {
            if (d.kind != .function) continue;
            const candidate: Decl = .{ .file = file, .index = @fromBackingInt(@intCast(i)) };
            if (self.scopeNode(candidate) != parent) continue;
            if (self.derivedParameter(candidate, node, 0) != null) return true;
            break;
        }
    }
    return false;
}

/// Whether `call` reaches `target` as a method of a value, which takes the value first.
fn methodCall(self: *const Facts, file: Project.FileId, call: Ast.full.Call, target: Decl) bool {
    const t = self.syntaxOf(file);
    if (t.nodeTag(call.ast.fn_expr) != .field_access) return false;
    const target_tree = self.syntaxOf(target.file);
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = target_tree.fullFnProto(&fn_buffer, self.project.at(target.file).model.declarations[@backingInt(target.index)].node) orelse return false;
    var count: usize = 0;
    var it = proto.iterate(target_tree);
    while (it.next()) |_| count += 1;
    return count == call.ast.params.len + 1;
}

/// The generic parameter of `function` that `node` is or is a part of: the parameter itself, a
/// value of it, or what a capture or a constant reads of its type information.
fn derivedParameter(self: *const Facts, function: Decl, node: Ast.Node.Index, depth: usize) ?usize {
    if (depth == 8) return null;
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const first = t.firstToken(node);
    const last = t.lastToken(node);
    for (first..last + 1) |raw| {
        const token: Ast.TokenIndex = @intCast(raw);
        if (t.tokenTag(token) != .identifier) continue;
        const scope = model.scopeOf(token);
        const index = self.lexical(function.file, scope, t.tokenSlice(token)) orelse continue;
        const record = model.declarations[@backingInt(index)];
        if (self.genericPosition(function, index)) |position| return position;
        if (self.valueOfParameter(function, index)) |position| return position;
        if (!self.enclosed(function.file, record.scope, self.scopeNode(function))) continue;
        const source: Ast.Node.Index = switch (record.kind) {
            .variable => (t.fullVarDecl(record.node) orelse continue).ast.init_node.unwrap() orelse continue,
            .capture => self.captureSource(function.file, record.node) orelse continue,
            else => continue,
        };
        if (source == node) continue;
        if (self.derivedParameter(function, source, depth + 1)) |position| return position;
    }
    return null;
}

/// The generic parameter of `function` whose value at run time `node` reads, itself or
/// through a local: a value of one (`value: T`, `anytype`), or what calling one returns
/// (`handler()`, `T.init()`). A type parameter's declarations, a `comptime` parameter's parts
/// and what `@typeInfo` tells of them are known as the program compiles: none.
fn runtimeParameter(self: *const Facts, function: Decl, node: Ast.Node.Index, depth: usize) ?usize {
    if (depth == 8) return null;
    const t = self.syntaxOf(function.file);
    const model = &self.project.at(function.file).model;
    const last = t.lastToken(node);
    var skip_to: Ast.TokenIndex = 0;
    for (t.firstToken(node)..last + 1) |raw| {
        const token: Ast.TokenIndex = @intCast(raw);
        if (token < skip_to) continue;
        // What a type query is given is never evaluated: `@TypeOf(x)`, `@sizeOf(T)`.
        if (t.tokenTag(token) == .builtin and unevaluated(t.tokenSlice(token)) and token < last and t.tokenTag(token + 1) == .l_paren) {
            skip_to = closing(t, token + 1, last) + 1;
            continue;
        }
        if (t.tokenTag(token) != .identifier) continue;
        const index = self.lexical(function.file, model.scopeOf(token), t.tokenSlice(token)) orelse continue;
        const record = model.declarations[@backingInt(index)];
        if (self.valueOfParameter(function, index)) |position| return position;
        if (self.genericPosition(function, index)) |position| {
            // `p(...)`, `p.f(...)`.
            var next = token + 1;
            while (next + 1 <= last and t.tokenTag(next) == .period and t.tokenTag(next + 1) == .identifier) next += 2;
            if (next <= last and t.tokenTag(next) == .l_paren) return position;
            continue;
        }
        if (record.kind != .variable or !self.enclosed(function.file, record.scope, self.scopeNode(function))) continue;
        const v = t.fullVarDecl(record.node) orelse continue;
        if (v.comptime_token != null) continue;
        const init = v.ast.init_node.unwrap() orelse continue;
        if (init == node) continue;
        if (self.runtimeParameter(function, init, depth + 1)) |position| return position;
    }
    return null;
}

/// Whether `node` is inside a `comptime` block or expression.
fn inComptime(t: *const Ast, model: *const Model, node: Ast.Node.Index) bool {
    var up = model.parentOf(node);
    while (up) |parent| : (up = model.parentOf(parent)) switch (t.nodeTag(parent)) {
        .@"comptime" => return true,
        .fn_decl => return false,
        else => {},
    };
    return false;
}

/// Whether a builtin only asks what its operands' types are, never evaluating them.
fn unevaluated(name: []const u8) bool {
    const queries = [_][]const u8{ "@TypeOf", "@typeInfo", "@sizeOf", "@alignOf", "@bitSizeOf", "@typeName", "@hasDecl", "@hasField", "@FieldType" };
    for (queries) |each| if (std.mem.eql(u8, name, each)) return true;
    return false;
}

/// The token closing the parenthesis that opens at `open`, at most `last`.
fn closing(t: *const Ast, open: Ast.TokenIndex, last: Ast.TokenIndex) Ast.TokenIndex {
    var depth: usize = 0;
    var token = open;
    while (token <= last) : (token += 1) switch (t.tokenTag(token)) {
        .l_paren => depth += 1,
        .r_paren => {
            depth -= 1;
            if (depth == 0) return token;
        },
        else => {},
    };
    return last;
}

/// The declaration `name` reaches from `scope`, looking outward.
fn lexical(self: *const Facts, file: Project.FileId, scope: Model.Scope.Id, name: []const u8) ?Model.Declaration.Id {
    const scopes = self.project.at(file).model.scopes;
    var at: ?Model.Scope.Id = scope;
    while (at) |s| : (at = scopes[@backingInt(s)].parent) if (scopes[@backingInt(s)].names.get(name)) |index| return index;
    return null;
}

/// What a capture is read from: a switch's subject, a loop's inputs, an `if`'s condition.
pub fn captureSource(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ?Ast.Node.Index {
    const t = self.syntaxOf(file);
    if (t.fullSwitchCase(node) != null) {
        const parent = self.project.at(file).model.parentOf(node) orelse return null;
        return (t.fullSwitch(parent) orelse return null).ast.condition;
    }
    if (t.fullFor(node)) |loop| return if (loop.ast.inputs.len != 0) loop.ast.inputs[0] else null;
    if (t.fullIf(node)) |branch| return branch.ast.cond_expr;
    if (t.fullWhile(node)) |loop| return loop.ast.cond_expr;
    return null;
}

/// The comptime `bool` parameter `node` names, if it names one.
fn conditionParameter(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ?Decl {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter or !comptimeBool(tree, record)) return null;
    return .{ .file = file, .index = index };
}

/// The comptime enum parameter a `switch` operand names: one declared `comptime x: T` with `T`
/// a named type other than `type` and `bool`, whose prongs name its tags.
fn switchParameter(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) ?Decl {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) != .identifier) return null;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter or !comptimeNamed(tree, record)) return null;
    return .{ .file = file, .index = index };
}

fn comptimeNamed(tree: *const Ast, record: Model.Declaration) bool {
    if (record.token == 0 or tree.tokenTag(record.token - 1) != .keyword_comptime) return false;
    return switch (tree.nodeTag(record.node)) {
        .identifier => !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(record.node)), "type") and !std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(record.node)), "bool"),
        .field_access => true,
        else => false,
    };
}

fn comptimeBool(tree: *const Ast, record: Model.Declaration) bool {
    return record.token > 0 and tree.tokenTag(record.token - 1) == .keyword_comptime and tree.nodeTag(record.node) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(record.node)), "bool");
}

/// Whether `file` declares a comptime `bool` or enum parameter, whose conditions paths can settle.
fn hasConditions(self: *Facts, file: Project.FileId) ResolveError!bool {
    if (self.conditional_files.get(file)) |known| return known;
    const tree = &self.project.at(file).file.tree;
    const any = for (self.project.at(file).model.declarations) |record| {
        if (record.kind == .parameter and (comptimeBool(tree, record) or comptimeNamed(tree, record))) break true;
    } else false;
    try self.conditional_files.put(self.gpa, file, any);
    return any;
}

/// A condition's value where it is known at compile time on this reading: `true`, `false`, a
/// comptime `bool` parameter the reading's call binds to a known value or the path settles,
/// and `!` of one.
fn truth(self: *const Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ?bool {
    const tree = &self.project.at(file).file.tree;
    switch (tree.nodeTag(node)) {
        .grouped_expression => return self.truth(env, file, tree.nodeData(node).node_and_token[0]),
        .@"comptime" => return self.truth(env, file, tree.nodeData(node).node),
        .bool_not => return if (self.truth(env, file, tree.nodeData(node).node)) |t| !t else null,
        .identifier => {},
        else => return null,
    }
    const spelled = tree.tokenSlice(tree.nodeMainToken(node));
    if (std.mem.eql(u8, spelled, "true")) return true;
    if (std.mem.eql(u8, spelled, "false")) return false;
    const model = &self.project.at(file).model;
    const index = (model.reference(node) orelse return null).declaration orelse return null;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .parameter) return null;
    if (env) |e| if (file == e.function.file and model.scopes[@backingInt(record.scope)].node == self.scopeNode(e.function)) {
        const position = self.parameterPosition(file, e.function, record.token) orelse return null;
        return if (position < e.truths.len) e.truths[position] else null;
    };
    for (self.assumptions(self.assumed)) |held| if (held.parameter.file == file and held.parameter.index == index) return if (held.value == .boolean) held.value.boolean else null;
    return null;
}

/// Whether a branch never completes: a jump or a stop, or a block whose last statement is one.
fn completesNever(tree: *const Ast, node: Ast.Node.Index) bool {
    if (never(tree, node) and tree.nodeTag(node) != .identifier) return true;
    // An `if` neither of whose branches completes.
    if (tree.fullIf(node)) |whole| {
        const otherwise = whole.ast.else_expr.unwrap() orelse return false;
        return completesNever(tree, whole.ast.then_expr) and completesNever(tree, otherwise);
    }
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node) orelse return false;
    if (statements.len == 0) return false;
    return completesNever(tree, statements[statements.len - 1]);
}

fn boxed(self: *Facts, value: Value) ResolveError!*const Value {
    // The caller gives a scratch arena. Values and memoized facts share its lifetime.
    const box = try self.gpa.create(Value);
    box.* = value;
    return box;
}

fn resolveInner(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
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
        // payload's type, as `x.?` has, where the other side coerces to it; the peer type of
        // both where the other side wraps the payload itself (`opt orelse f()` with `f`
        // returning `E!T` is an `E!T`, `x catch null` a `?T`).
        .@"catch", .@"orelse" => {
            const sides = tree.nodeData(node).node_and_node;
            const wrapper: std.meta.Tag(Value) = if (tag == .@"catch") .error_union else .optional;
            const inner = try self.payload(try self.resolve(file, sides[0]), wrapper);
            if (inner == .unknown or never(tree, sides[1])) return inner;
            return switch (try self.resolve(file, sides[1])) {
                .error_union => if (tag == .@"orelse") .{ .error_union = try self.boxed(inner) } else inner,
                .optional => if (tag == .@"catch") .{ .optional = try self.boxed(inner) } else inner,
                else => inner,
            };
        },
        .unwrap_optional => return self.payload(try self.resolve(file, tree.nodeData(node).node_and_token[0]), .optional),
        .@"switch", .switch_comma, .@"if" => if (try self.branches(null, file, node)) |value| return value,
        .block, .block_semicolon, .block_two, .block_two_semicolon => if (try self.breaks(null, file, node)) |value| return value,
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
        .enum_literal => return self.declarationLiteral(file, node),
        .number_literal, .string_literal, .char_literal => return .scalar,
        else => {},
    }
    if (try self.typeWritten(file, node)) |value| return value;
    var buffer: [2]Ast.Node.Index = undefined;
    switch (tag) {
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return self.builtin(null, file, node),
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node).?;
            const callee = try self.resolve(file, call.ast.fn_expr);
            if (callee == .alternatives) return self.map(callee, {}, callResult);
            if (callee == .function) {
                if (try self.typeArgument(file, call, callee.function)) |result| return result;
                // A made container's method read with the container's bindings; where its own
                // generic parameters leave the result unknown, the call's reading of them.
                const made = try self.madeResult(file, call, callee.function);
                if (made) |value| if (!unknownWithin(value)) return value;
                if (try self.evaluateCall(null, file, call, callee.function)) |value| return value;
                if (made) |value| return value;
                var result = try self.callResult(callee, {});
                if (result == .container and result.container.symbolic) {
                    result.container.made_by = try self.making(.{ .function = callee.function, .file = file, .call = node, .assumed = self.assumed });
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
        // A tuple with no type of its own (`.{ sha2.Sha256, .sha256 }`), as a struct literal is.
        .array_init_dot, .array_init_dot_comma, .array_init_dot_two, .array_init_dot_two_comma => return .{ .literal = .{ .file = file, .node = node } },
        .address_of => return .{ .pointer = try self.boxed(try self.resolve(file, tree.nodeData(node).node)) },
        .deref => return self.pointee(try self.resolve(file, tree.nodeData(node).node), {}),
        .@"try" => return self.payload(try self.resolve(file, tree.nodeData(node).node), .error_union),
        else => return .{ .unknown = .unsupported },
    }
}

/// A type written in place: a pointer, an array, a function type, a container.
fn typeWritten(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    if (tree.fullPtrType(node)) |ptr| return .{ .pointer = try self.boxed(try self.resolve(file, ptr.ast.child_type)) };
    if (tree.fullArrayType(node)) |array| return .{ .array = try self.boxed(try self.resolve(file, array.ast.elem_type)) };
    var proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.nodeTag(node) != .fn_decl and tree.fullFnProto(&proto_buffer, node) != null) return .{ .fn_type = .{ .file = file, .node = node } };
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, node) != null) {
        for (self.project.at(file).model.scopes, 0..) |scope, s| if (scope.kind == .container and scope.node == node) return .{ .container = .{ .file = file, .scope = @fromBackingInt(@intCast(s)) } };
    }
    return null;
}

/// What a builtin call gives: an imported file, `@This()`, a reflected declaration, a type
/// `@as` names, a value's type, a type's information; its operands read with `env`'s
/// bindings where a generic call's reading gives them.
fn builtin(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var buffer: [2]Ast.Node.Index = undefined;
    const name = tree.tokenSlice(tree.nodeMainToken(node));
    const args = builtinArgs(tree, node, &buffer);
    if (std.mem.eql(u8, name, "@import")) {
        if (args.len != 1 or tree.nodeTag(args[0]) != .string_literal) return .{ .unknown = .computed_import };
        const spelling = std.zig.string_literal.parseAlloc(self.gpa, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidLiteral => return .{ .unknown = .computed_import },
        };
        const target = self.project.imported(file, spelling) orelse return .{ .unknown = if (self.project.absent(file, spelling))
            .absent
        else if (try self.zigOwn(file, spelling))
            .std_internal
        else
            .missing_mapping };
        return .{ .container = self.rootOf(target) };
    }
    if (std.mem.eql(u8, name, "@This")) {
        var scope: ?Model.Scope.Id = model.scopeOf(tree.nodeMainToken(node));
        while (scope) |s| {
            if (model.scopes[@backingInt(s)].kind == .container or model.scopes[@backingInt(s)].kind == .file) return .{ .container = .{ .file = file, .scope = s } };
            scope = model.scopes[@backingInt(s)].parent;
        }
    }
    if ((std.mem.eql(u8, name, "@field") or std.mem.eql(u8, name, "@hasDecl")) and args.len == 2) {
        const target = (try self.reflected(file, node)) orelse return .{ .unknown = .comptime_dependent };
        if (std.mem.eql(u8, name, "@hasDecl")) return .scalar;
        return self.declaration(target);
    }
    if (std.mem.eql(u8, name, "@as") and args.len == 2) {
        const named = try self.resolveIn(env, file, args[0]);
        // A type, or types, held as a value: what they are is the operand.
        if (holdsTypes(named)) return self.resolveIn(env, file, args[1]);
        return self.instance(named);
    }
    // Every element the operand: an array of it (a vector is indexed as one).
    if (std.mem.eql(u8, name, "@splat") and args.len == 1) return .{ .array = try self.boxed(try self.resolveIn(env, file, args[0])) };
    // A type built from its fields' types: `@Struct(layout, backing, names, types, attributes)`,
    // `@Union(layout, tag, names, types, attributes)`, `@Tuple(types)`.
    if ((std.mem.eql(u8, name, "@Struct") or std.mem.eql(u8, name, "@Union")) and args.len == 5) return self.reified(try self.resolveIn(env, file, args[3]));
    if (std.mem.eql(u8, name, "@Tuple") and args.len == 1) return self.reified(try self.resolveIn(env, file, args[0]));
    // `@Pointer(size, attributes, child, sentinel)`: a pointer to `child`, as a slice or a
    // many-item pointer is too.
    if (std.mem.eql(u8, name, "@Pointer") and args.len == 4) {
        const child = try self.resolveIn(env, file, args[2]);
        if (child == .unknown) return child;
        return .{ .pointer = try self.boxed(child) };
    }
    // A vector is indexed as an array of its lanes, and holds only numbers, truth values and
    // pointers.
    if (std.mem.eql(u8, name, "@Vector") and args.len == 2) return .{ .array = try self.boxed(try self.resolveIn(env, file, args[1])) };
    if (std.mem.eql(u8, name, "@FieldType") and args.len == 2) return self.fieldType(file, try self.resolveIn(env, file, args[0]), args[1]);
    if (std.mem.eql(u8, name, "@TypeOf") and args.len == 1) return self.map(try self.resolveIn(env, file, args[0]), {}, typeOf);
    if (std.mem.eql(u8, name, "@typeInfo") and args.len == 1) return self.reflect(try self.resolveIn(env, file, args[0]));
    // A name's bytes: `[:0]const u8`, or the file's bytes for `@embedFile`.
    for ([_][]const u8{ "@errorName", "@tagName", "@typeName", "@embedFile" }) |bytes| if (std.mem.eql(u8, name, bytes)) return .{ .pointer = try self.boxed(.{ .primitive = "u8" }) };
    // A number or a truth value, whatever the arguments are.
    for (numeric_builtins) |number| if (std.mem.eql(u8, name, number)) return .scalar;
    // Values of std's own types, as the language gives them.
    if (std.mem.eql(u8, name, "@errorReturnTrace")) {
        const trace = try self.stdMember(&.{ "builtin", "StackTrace" });
        if (trace == .unknown) return trace;
        return .{ .optional = try self.boxed(.{ .pointer = try self.boxed(try self.instance(trace)) }) };
    }
    if (std.mem.eql(u8, name, "@src")) return self.instance(try self.stdMember(&.{ "builtin", "SourceLocation" }));
    return .{ .unknown = .comptime_dependent };
}

/// Whether a value is type information (`@typeInfo(T)`), or a choice of it.
fn reflectedInfo(value: Value) bool {
    const each: []const Value = if (value == .alternatives) value.alternatives else &.{value};
    for (each) |one| if (one != .reflected or one.reflected.at != .info) return false;
    return true;
}

/// Whether a value is unknown, itself or what a pointer, optional, error union or array holds.
fn unknownWithin(value: Value) bool {
    return switch (value) {
        .unknown => true,
        .pointer, .optional, .error_union, .array => |inner| unknownWithin(inner.*),
        else => false,
    };
}

/// A declaration of std's by its path from std's root (`builtin.StackTrace`), where the
/// project maps std.
fn stdMember(self: *Facts, path: []const []const u8) ResolveError!Value {
    const root = for (self.project.imports) |mapping| {
        if (std.mem.eql(u8, mapping.spelling, "std")) break mapping.target;
    } else return .{ .unknown = .missing_mapping };
    var value: Value = .{ .container = self.rootOf(root) };
    for (path) |name| value = try self.memberValue(value, name);
    return value;
}

/// Whether a declared type holds types as values: `type`, `[N]type`, `[]const type`, `?type`.
fn holdsTypes(value: Value) bool {
    return switch (value) {
        .primitive => |name| std.mem.eql(u8, name, "type"),
        .pointer, .array, .optional => |inner| holdsTypes(inner.*),
        else => false,
    };
}

/// A type built from `types`, a list of its fields' types (an array of them, a pointer to one,
/// or a tuple literal of them): one that holds what they do.
fn reified(self: *Facts, types: Value) ResolveError!Value {
    const each: Value = switch (types) {
        .pointer => |inner| return self.reified(inner.*),
        .array => |inner| inner.*,
        .literal => |literal| blk: {
            const parts = try self.literalParts(literal);
            if (parts.len == 0) return .{ .unknown = .unsupported };
            break :blk try self.choose(parts);
        },
        .alternatives => return self.map(types, {}, reifiedEach),
        .unknown => return types,
        else => return .{ .unknown = .unsupported },
    };
    if (each == .unknown) return each;
    return .{ .reified = .{ .fields = try self.boxed(each) } };
}
fn reifiedEach(self: *Facts, types: Value, _: void) ResolveError!Value {
    return self.reified(types);
}

/// `@FieldType(T, name)`: the type of `T`'s field `name`; for a name computed at compile
/// time, one of its fields' types, each a choice.
fn fieldType(self: *Facts, file: Project.FileId, of: Value, name_node: Ast.Node.Index) ResolveError!Value {
    const container = switch (of) {
        .container => |c| c,
        .unknown => |why| return .{ .unknown = why },
        else => return .{ .unknown = .unsupported },
    };
    // A container a type function makes has its fields' types where the call that made it is
    // known, read with that call's bindings.
    if (container.symbolic and container.made_by == null) return .{ .unknown = .comptime_dependent };
    const t = self.syntaxOf(file);
    if (t.nodeTag(name_node) == .string_literal) {
        const name = std.zig.string_literal.parseAlloc(self.gpa, t.tokenSlice(t.nodeMainToken(name_node))) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .unknown = .unsupported },
        };
        const field = self.member(container, name) orelse return .{ .unknown = .unresolved };
        return typeOf(self, try self.memberOf(container, field), {});
    }
    const model = &self.project.at(container.file).model;
    var each: std.ArrayList(Value) = .empty;
    for (model.declarations, 0..) |d, i| {
        if (d.kind != .field or d.scope != container.scope) continue;
        const field = self.syntaxOf(container.file).fullContainerField(d.node) orelse continue;
        if (field.ast.type_expr == .none) continue;
        try each.append(self.gpa, try typeOf(self, try self.memberOf(container, .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) }), {}));
    }
    if (each.items.len == 0) return .{ .unknown = .unsupported };
    return self.choose(each.items);
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
        // An array's one member is its length, a number.
        .array => return if (std.mem.eql(u8, name, "len")) .scalar else .{ .unknown = .unresolved },
        .unknown => return lhs,
        else => return .{ .unknown = .unresolved },
    };
    // A tag named on an enum or a union type (`Color.red`, `Shape.empty`): a value of it.
    if (lhs == .container and self.declaresTag(container, name)) return .{ .instance = container };
    if (self.member(container, name)) |decl| return self.memberOf(container, decl);
    return .{ .unknown = .unresolved };
}

/// Whether `container` is an `enum` or a `union` with a field `name`, one of its tags. An
/// enum's field is written as a bare name, which Zig's syntax tree reads as a tuple's field.
fn declaresTag(self: *const Facts, container: Container, name: []const u8) bool {
    const node = self.project.at(container.file).model.scopes[@backingInt(container.scope)].node;
    if (node == .root) return false;
    const tree = self.syntaxOf(container.file);
    var buffer: [2]Ast.Node.Index = undefined;
    const decl = tree.fullContainerDecl(&buffer, node) orelse return false;
    switch (tree.tokenTag(decl.ast.main_token)) {
        .keyword_enum, .keyword_union => {},
        else => return false,
    }
    for (decl.ast.members) |member_node| {
        var field = tree.fullContainerField(member_node) orelse continue;
        field.convertToNonTupleLike(tree);
        if (field.ast.tuple_like) continue;
        if (std.mem.eql(u8, Model.identifier(self.gpa, tree.tokenSlice(field.ast.main_token)) catch return false, name)) return true;
    }
    return false;
}

/// Whether a container written in the program declares no member `name`.
fn lacks(self: *const Facts, container: Container, name: []const u8) bool {
    return !container.symbolic and self.member(container, name) == null;
}

/// A field of an anonymous struct literal: the value the literal gives it.
fn literalField(self: *Facts, literal: Key, name: []const u8) ResolveError!Value {
    const tree = &self.project.at(literal.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const full = tree.fullStructInit(&buffer, literal.node) orelse return .{ .unknown = .unsupported };
    for (full.ast.fields) |field| {
        const label = try self.memberName(tree.tokenSlice(Model.initName(tree, field) orelse continue));
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
        // An optional or error union has no member a name reads, and an array only its length:
        // the choice that holds one is another.
        .optional, .error_union => continue,
        .array => if (!std.mem.eql(u8, name, "len")) continue else try kept.append(self.gpa, try self.memberValue(choice, name)),
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
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    // A type it declares (`Replay`, `Record`) is made by the same call; a declaration naming
    // one made elsewhere (`const Record = State.Record;`) is read with the call's bindings, as
    // a field's type is, the template's reading standing where that reading is unknown.
    if (record.kind != .field) {
        if (record.kind == .variable) if (tree.fullVarDecl(record.node)) |variable| if (variable.ast.type_node == .none) if (variable.ast.init_node.unwrap()) |init| {
            const value = try self.substituted(decl.file, init, made);
            if (value != .unknown) return self.madeWithin(value, container, made);
        };
        return self.madeWithin(try self.declaration(decl), container, made);
    }
    const field = tree.fullContainerField(record.node) orelse return self.declaration(decl);
    const type_node = field.ast.type_expr.unwrap() orelse return self.declaration(decl);
    const value = try self.substituted(decl.file, type_node, made);
    if (value == .unknown) {
        // The template's reading is what every instantiation makes of the field; it stands for
        // this one only where they agree.
        const template_value = try self.declaration(decl);
        return if (template_value == .alternatives) value else template_value;
    }
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
    const tree = &self.project.at(file).file.tree;
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
    const model = &self.project.at(decl.file).model;
    const target_tree = &self.project.at(decl.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(decl.index)].node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    const generic: Generic = .{ .file = file, .call = call, .decl = decl, .function = function, .receiver = receiver };
    const result = (try self.written(generic, result_node, 0)) orelse return null;
    // `!T`: an error union whose error set the body infers.
    if (Model.inferredErrors(target_tree, result_node)) return .{ .error_union = try self.boxed(result) };
    return result;
}

/// A generic function called: where, how and what it declares.
const Generic = struct { file: Project.FileId, call: Ast.full.Call, decl: Decl, function: Ast.full.FnProto, receiver: usize };

/// A result type written in terms of a `comptime T: type` parameter (`T`, `*T`, `?T`, `[]T`,
/// `[N]T`, `E!*T`), with the call's argument for `T`; null for any other result.
fn written(self: *Facts, generic: Generic, node: Ast.Node.Index, depth: usize) ResolveError!?Value {
    if (depth == 16) return null;
    const model = &self.project.at(generic.decl.file).model;
    const target_tree = &self.project.at(generic.decl.file).file.tree;
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
    const parameter = model.declarations[@backingInt(index)];
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
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(call.ast.fn_expr) != .field_access) return null;
    const receiver = try self.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
    // A method called on a value of it, or a function called through the made type itself
    // (`Held.initFrom(source)` of `const Held = Owned(Payload, release)`).
    const container = switch (receiver) {
        .instance, .container => |c| c,
        .pointer => |p| switch (p.*) {
            .instance, .container => |c| c,
            else => return null,
        },
        else => return null,
    };
    const made = container.made_by orelse return null;
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (decl.file != container.file or record.scope != container.scope) return null;
    const target_tree = &self.project.at(decl.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, record.node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    // A type function declared in it makes its own container: read as a template.
    if (typeKeyword(target_tree, result_node)) return null;
    // A result written in terms of the method's own generic parameters (`Result(parser)`) is
    // this call's: the container's bindings alone would read them as every call's.
    if (namesGenericParameter(target_tree, function, result_node)) return null;
    var result = try self.substituted(decl.file, result_node, made);
    if (result == .unknown) return null;
    // A container declared beside the receiver's own in what the call made (an iterator's
    // `Entry`, declared in the map) is made by the same call.
    result = try self.madeWithin(result, self.madeOuter(container, made), made);
    if (Model.inferredErrors(target_tree, result_node)) return .{ .error_union = try self.boxed(try self.instance(result)) };
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

/// The outermost container around `container` that a type function returns: the one its
/// call made, of which `container` (an iterator, a guard) is a part. A type function's
/// container sits in its body, whose scope is no container's.
fn madeOuter(self: *const Facts, container: Container, made: *const Made) Container {
    const model = &self.project.at(container.file).model;
    var outer = container.scope;
    while (model.scopes[@backingInt(outer)].parent) |parent| {
        const scope = model.scopes[@backingInt(parent)];
        // A file's own scope holds no type function's container.
        if (scope.kind != .container or scope.parent == null) break;
        outer = parent;
    }
    return .{ .file = container.file, .scope = outer, .symbolic = container.symbolic, .made_by = made };
}

fn within(self: *const Facts, inner: Container, outer: Container) bool {
    if (inner.file != outer.file) return false;
    // The made container itself (`Self`), as a method's result names it.
    if (inner.scope == outer.scope) return true;
    const scopes = self.project.at(inner.file).model.scopes;
    var scope: ?Model.Scope.Id = scopes[@backingInt(inner.scope)].parent;
    while (scope) |s| : (scope = scopes[@backingInt(s)].parent) if (s == outer.scope) return true;
    return false;
}

/// A type expression written inside a type function's container, its parameters read as the
/// arguments of the call that made it: the same reading as a generic call's (`resolveIn`).
fn substituted(self: *Facts, file: Project.FileId, node: Ast.Node.Index, made: *const Made) ResolveError!Value {
    return self.resolveIn(try self.madeEnv(made), file, node);
}

/// The call that makes a type function's container, followed through type functions that
/// return another's call: the innermost one, read with the bindings of those around it.
fn making(self: *Facts, outer: Made) ResolveError!*const Made {
    var current = try self.gpa.create(Made);
    current.* = outer;
    for (0..8) |_| {
        const next = (try self.forwarded(current.function)) orelse break;
        const inner = try self.gpa.create(Made);
        inner.* = .{ .function = next.function, .file = current.function.file, .call = next.call, .via = current, .assumed = current.assumed };
        current = inner;
    }
    return current;
}

/// The call a type function's final `return` makes of another type function, when it
/// returns one: `return Owner(T, false, cleanup);`.
fn forwarded(self: *Facts, function: Decl) ResolveError!?struct { function: Decl, call: Ast.Node.Index } {
    const tree = &self.project.at(function.file).file.tree;
    const record = self.project.at(function.file).model.declarations[@backingInt(function.index)];
    if (record.kind != .function) return null;
    const returned = finalReturn(tree, &self.project.at(function.file).model, record) orelse return null;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, returned) orelse return null;
    const callee = (try self.definition(function.file, call.ast.fn_expr)) orelse return null;
    const target = (try self.origin(callee)) orelse return null;
    if (self.project.at(target.file).model.declarations[@backingInt(target.index)].kind != .function) return null;
    return .{ .function = target, .call = returned };
}

/// The bindings of the call that made a container: the type function's parameters bound to its
/// arguments (read with the bindings of the reading that made it, if any). A parameter the
/// function passes on changed when it calls itself again is not the call's argument on that
/// path, so it stays unknown.
fn madeEnv(self: *Facts, made: *const Made) ResolveError!*const Env {
    const call_tree = &self.project.at(made.file).file.tree;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = call_tree.fullCall(&call_buffer, made.call).?;
    // The bindings of the reading the call is in: a calling reading's, or a forwarding type
    // function's call.
    const outer_env: ?*const Env = if (made.via) |via| try self.madeEnv(via) else made.env;
    // Read where the call was: under what its path settled.
    const outer = self.assumed;
    defer self.assumed = outer;
    self.assumed = made.assumed;
    const args = try self.gpa.alloc(Value, call.ast.params.len);
    const truths = try self.gpa.alloc(?bool, call.ast.params.len);
    for (call.ast.params, args, truths, 0..) |param, *arg, *t, position| {
        const changed = try self.passedOnChanged(made.function, position);
        arg.* = if (changed)
            .{ .unknown = .comptime_dependent }
        else if (outer_env) |env| try self.resolveIn(env, made.file, param) else try self.resolve(made.file, param);
        t.* = if (changed) null else self.truth(outer_env, made.file, param);
    }
    const env = try self.gpa.create(Env);
    env.* = .{ .function = made.function, .args = args, .depth = if (outer_env) |e| e.depth +| 1 else 0, .truths = truths };
    return env;
}

fn passedOnChanged(self: *const Facts, function: Decl, position: usize) ResolveError!bool {
    const tree = &self.project.at(function.file).file.tree;
    const fn_node = self.scopeNode(function);
    if (tree.nodeTag(fn_node) != .fn_decl) return false;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return false;
    if (statements.len == 0) return false;
    const changed = self.recursion(function, body, statements[statements.len - 1]) orelse return false;
    return position < 64 and changed & (@as(u64, 1) << @intCast(position)) != 0;
}

/// What calling `callee` returns: its declared result, or the container a type function makes.
fn callResult(self: *Facts, callee: Value, _: void) ResolveError!Value {
    if (callee == .function) {
        const decl = callee.function;
        const declaration_record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
        const target_tree = &self.project.at(decl.file).file.tree;
        var fn_buffer: [1]Ast.Node.Index = undefined;
        const function = target_tree.fullFnProto(&fn_buffer, declaration_record.node).?;
        const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
        // `!T`: an error union whose error set the body infers.
        if (Model.inferredErrors(target_tree, result_node)) {
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
    // A value of a function type (`comptime read: fn (u8) T`): what the type declares it
    // returns, whichever function is passed.
    if (callee == .fn_type) {
        const result = try self.resultOf(callee.fn_type);
        if (result == .unknown or (result == .primitive and std.mem.eql(u8, result.primitive, "type"))) return .{ .unknown = .comptime_dependent };
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
/// makes the others optional, an error value (`error.Name`) an error union.
fn branches(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    var values: std.ArrayList(Value) = .empty;
    var peers: Peers = .{};
    if (tree.fullSwitch(node)) |whole| {
        for (whole.ast.cases) |case| {
            const branch = tree.fullSwitchCase(case).?.ast.target_expr;
            // A prong the path rules out: Zig analyses only the one a comptime operand takes.
            if (never(tree, branch) or try self.dead(file, branch)) continue;
            if (peers.literal(tree, branch)) continue;
            try values.append(self.gpa, try self.resolveIn(env, file, branch));
        }
    } else if (tree.fullIf(node)) |whole| {
        const otherwise = whole.ast.else_expr.unwrap() orelse return null;
        // A condition known at compile time: Zig analyses only the branch it takes.
        const taken: []const Ast.Node.Index = if (whole.payload_token == null and whole.error_token == null) if (self.truth(env, file, whole.ast.cond_expr)) |t|
            if (t) &.{whole.ast.then_expr} else &.{otherwise}
        else
            &.{ whole.ast.then_expr, otherwise } else &.{ whole.ast.then_expr, otherwise };
        for (taken) |branch| {
            if (never(tree, branch)) continue;
            if (peers.literal(tree, branch)) continue;
            try values.append(self.gpa, try self.resolveIn(env, file, branch));
        }
    } else return null;
    return try self.peered(try self.choose(values.items), peers);
}

/// What a `null` or an error value among a value's branches or breaks adds to the others:
/// Zig makes them optional, or an error union.
const Peers = struct {
    nullable: bool = false,
    fallible: bool = false,

    /// Whether `node` is `null` or an error value, noted as such.
    fn literal(peers: *Peers, tree: *const Ast, node: Ast.Node.Index) bool {
        if (isNull(tree, node)) {
            peers.nullable = true;
            return true;
        }
        if (tree.nodeTag(node) == .error_value) {
            peers.fallible = true;
            return true;
        }
        return false;
    }
};
fn peered(self: *Facts, chosen: Value, peers: Peers) ResolveError!Value {
    if (chosen == .unknown) return chosen;
    const optional: Value = if (!peers.nullable) chosen else switch (chosen) {
        .optional => chosen,
        // `E!T` and `null`: `E!?T`.
        .error_union => |held| if (held.* == .optional) chosen else .{ .error_union = try self.boxed(.{ .optional = held }) },
        else => .{ .optional = try self.boxed(chosen) },
    };
    if (!peers.fallible or optional == .error_union) return optional;
    return .{ .error_union = try self.boxed(optional) };
}

/// A labeled block: what its `break`s give it, chosen as one, as a `switch`'s branches are.
fn breaks(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    const brace = tree.nodeMainToken(node);
    if (brace < 2 or tree.tokenTag(brace - 1) != .colon or tree.tokenTag(brace - 2) != .identifier) return null;
    // Zig refuses a label that shadows another, so the name finds this block's breaks.
    const label = tree.tokenSlice(brace - 2);
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var values: std.ArrayList(Value) = .empty;
    var peers: Peers = .{};
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(jump);
        if (at < first or at > last) continue;
        const data = tree.nodeData(jump).opt_token_and_opt_node;
        const token = data[0].unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token), label)) continue;
        const operand = data[1].unwrap() orelse return null;
        if (never(tree, operand)) continue;
        // A break in a branch this instantiation does not take gives nothing.
        if (try self.dead(file, jump)) continue;
        if (peers.literal(tree, operand)) continue;
        try values.append(self.gpa, try self.resolveIn(env, file, operand));
    }
    return try self.peered(try self.choose(values.items), peers);
}

/// A loop used as a value (`const e = for (xs) |x| { if (p(x)) break x; } else null;`): what
/// its own breaks give, chosen with its `else` branch as a `switch`'s branches are. A break
/// is the loop's own when it names the loop's label, or names none and no loop nested in this
/// one encloses it.
fn loopValue(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Value {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    const body: Ast.Node.Index, const otherwise: Ast.Node.Index, const label: ?[]const u8 = if (tree.fullFor(node)) |loop|
        .{ loop.ast.then_expr, loop.ast.else_expr.unwrap() orelse return null, if (loop.label_token) |t| tree.tokenSlice(t) else null }
    else if (tree.fullWhile(node)) |loop|
        .{ loop.ast.then_expr, loop.ast.else_expr.unwrap() orelse return null, if (loop.label_token) |t| tree.tokenSlice(t) else null }
    else
        return null;
    var values: std.ArrayList(Value) = .empty;
    var peers: Peers = .{};
    const first = tree.firstToken(body);
    const last = tree.lastToken(body);
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .@"break") continue;
        const jump: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(jump);
        if (at < first or at > last) continue;
        const data = tree.nodeData(jump).opt_token_and_opt_node;
        if (data[0].unwrap()) |token| {
            if (label == null or !std.mem.eql(u8, tree.tokenSlice(token), label.?)) continue;
        } else {
            // The innermost loop around the break, short of this one, takes it.
            var up = model.parentOf(jump);
            const inner = while (up) |p| : (up = model.parentOf(p)) {
                if (p == node) break false;
                if (tree.fullFor(p) != null or tree.fullWhile(p) != null) break true;
            } else true;
            if (inner) continue;
        }
        const operand = data[1].unwrap() orelse return null;
        if (never(tree, operand)) continue;
        // A break in a branch this instantiation does not take gives nothing.
        if (try self.dead(file, jump)) continue;
        if (peers.literal(tree, operand)) continue;
        try values.append(self.gpa, try self.resolve(file, operand));
    }
    if (!peers.literal(tree, otherwise) and !never(tree, otherwise)) try values.append(self.gpa, try self.resolve(file, otherwise));
    if (values.items.len == 0) return null;
    return try self.peered(try self.choose(values.items), peers);
}

/// A call through a field that holds a function pointer (`read: *const fn (...) R`): what
/// the pointer's function type returns.
fn throughPointer(self: *Facts, file: Project.FileId, callee: Ast.Node.Index) ResolveError!?Value {
    var decl = (try self.definition(file, callee)) orelse return null;
    var record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    // A local holding the field, unwrapped: `const f = x.handler orelse return;`.
    if (record.kind == .variable) {
        const local = &self.project.at(decl.file).file.tree;
        var value = (local.fullVarDecl(record.node) orelse return null).ast.init_node.unwrap() orelse return null;
        while (true) value = switch (local.nodeTag(value)) {
            .@"orelse" => local.nodeData(value).node_and_node[0],
            .unwrap_optional, .grouped_expression => local.nodeData(value).node_and_token[0],
            else => break,
        };
        decl = (try self.definition(decl.file, value)) orelse return null;
        record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    }
    if (record.kind != .field) return null;
    const tree = &self.project.at(decl.file).file.tree;
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
        .grouped_expression => never(tree, tree.nodeData(node).node_and_token[0]),
        // Every branch leaves: an `if` with an `else`, a `switch`.
        .@"if", .if_simple => blk: {
            const branch = tree.fullIf(node).?; // unreachable: the tag is an `if`'s
            break :blk never(tree, branch.ast.then_expr) and never(tree, branch.ast.else_expr.unwrap() orelse break :blk false);
        },
        .@"switch", .switch_comma => for (tree.fullSwitch(node).?.ast.cases) |case| { // unreachable: the tag is a switch's
            if (!never(tree, tree.fullSwitchCase(case).?.ast.target_expr)) break false; // unreachable: a switch's cases are cases
        } else true,
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
fn captured(self: *Facts, env: ?*const Env, decl: Decl) ResolveError!Value {
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    const node = record.node;
    const name = record.token;
    const by_pointer = tree.tokenTag(name - 1) == .asterisk;
    const bound: Value = if (tree.fullIf(node)) |branch|
        try self.conditional(env, decl.file, branch.payload_token, branch.error_token, branch.ast.cond_expr, name)
    else if (tree.fullWhile(node)) |loop|
        try self.conditional(env, decl.file, loop.payload_token, loop.error_token, loop.ast.cond_expr, name)
    else if (tree.nodeTag(node) == .@"catch")
        .error_set
    else if (tree.fullSwitchCase(node)) |case|
        try self.switchPayload(env, decl.file, node, case, name)
    else if (tree.fullFor(node)) |loop|
        try self.element(env, decl.file, loop, name)
    else
        .{ .unknown = .unsupported };
    if (bound == .unknown or !by_pointer) return bound;
    return .{ .pointer = try self.boxed(bound) };
}

fn conditional(self: *Facts, env: ?*const Env, file: Project.FileId, payload_token: ?Ast.TokenIndex, error_token: ?Ast.TokenIndex, condition: Ast.Node.Index, name: Ast.TokenIndex) ResolveError!Value {
    if (error_token) |token| if (token == name) return .error_set;
    const first = payload_token orelse return .{ .unknown = .unsupported };
    if (first != name and first + 1 != name) return .{ .unknown = .unsupported };
    const value = try self.resolveIn(env, file, condition);
    return switch (value) {
        .optional, .error_union => |inner| inner.*,
        .unknown => value,
        else => .{ .unknown = .unsupported },
    };
}

fn switchPayload(self: *Facts, env: ?*const Env, file: Project.FileId, case_node: Ast.Node.Index, full: Ast.full.SwitchCase, name: Ast.TokenIndex) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    // The payload is the first capture; a second is the prong's tag.
    const first = full.payload_token orelse return .{ .unknown = .unsupported };
    if (first != name and first + 1 != name) return .{ .unknown = .unsupported };
    const parent = self.project.at(file).model.parentOf(case_node) orelse return .{ .unknown = .unsupported };
    const whole = tree.fullSwitch(parent) orelse return .{ .unknown = .unsupported };
    const subject = try self.resolveIn(env, file, whole.ast.condition);
    // A switch on type information (`@typeInfo(T)`) captures the part its prong names, of
    // each type a choice of them gives.
    if (reflectedInfo(subject)) {
        const each: []const Value = if (subject == .alternatives) subject.alternatives else &.{subject};
        const parts = try self.gpa.alloc(Value, each.len);
        for (each, parts) |one, *part| part.* = if (full.ast.values.len != 1 or tree.nodeTag(full.ast.values[0]) != .enum_literal)
            .{ .reflected = .{ .of = one.reflected.of, .at = .part } }
        else
            try self.reflectedMember(one.reflected, try self.memberName(tree.tokenSlice(tree.nodeMainToken(full.ast.values[0]))));
        return self.choose(parts);
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
    // A union's `else` prong captures the union itself; an `inline else` prong each payload.
    if (full.ast.values.len == 0 and full.inline_token == null) return .{ .instance = container };
    // The fields the prong takes: those its items name, or for `inline else` those no other
    // prong names.
    var fields: std.ArrayList(Decl) = .empty;
    if (full.ast.values.len == 0) {
        const model = &self.project.at(container.file).model;
        const owner = &self.project.at(container.file).file.tree;
        for (model.declarations, 0..) |record, i| {
            if (record.kind != .field or record.scope != container.scope) continue;
            const field_name = try self.memberName(owner.tokenSlice(record.token));
            if (try self.prongNames(file, whole, field_name)) continue;
            try fields.append(self.gpa, .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) });
        }
    } else for (full.ast.values) |item| {
        if (tree.nodeTag(item) != .enum_literal) return .{ .unknown = .unsupported };
        const field = self.member(container, try self.memberName(tree.tokenSlice(tree.nodeMainToken(item)))) orelse return .{ .unknown = .unresolved };
        if (self.project.at(field.file).model.declarations[@backingInt(field.index)].kind != .field) return .{ .unknown = .unsupported };
        try fields.append(self.gpa, field);
    }
    if (fields.items.len == 0) return .{ .unknown = .unsupported };
    const values = try self.gpa.alloc(Value, fields.items.len);
    for (fields.items, values) |field, *value| {
        // A field with no type holds `void`.
        const record = self.project.at(field.file).model.declarations[@backingInt(field.index)];
        const typed = self.project.at(field.file).file.tree.fullContainerField(record.node).?.ast.type_expr != .none;
        // Of a union a type function made, read with its call's bindings (`parsed: T`).
        value.* = if (typed) try self.memberOf(container, field) else .scalar;
        if (value.* == .unknown) return value.*;
    }
    // An `inline` prong is analysed once per field, its capture each one's payload in turn;
    // otherwise Zig requires the payloads to be one type.
    if (full.inline_token != null) return self.choose(values);
    for (values[1..]) |value| if (!same(values[0], value, 0)) return .{ .unknown = .unsupported };
    return values[0];
}

/// Whether a prong of `whole` names the union field `name`.
fn prongNames(self: *Facts, file: Project.FileId, whole: Ast.full.Switch, name: []const u8) ResolveError!bool {
    const tree = &self.project.at(file).file.tree;
    for (whole.ast.cases) |case| for (tree.fullSwitchCase(case).?.ast.values) |item| {
        if (tree.nodeTag(item) == .enum_literal and std.mem.eql(u8, try self.memberName(tree.tokenSlice(tree.nodeMainToken(item))), name)) return true;
    };
    return false;
}

fn element(self: *Facts, env: ?*const Env, file: Project.FileId, loop: Ast.full.For, name: Ast.TokenIndex) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const position = Model.capturePosition(tree, loop, name) orelse return .{ .unknown = .unsupported };
    if (position >= loop.ast.inputs.len) return .{ .unknown = .unsupported };
    const input = loop.ast.inputs[position];
    if (tree.nodeTag(input) == .for_range) return .scalar;
    return self.forElement(env, file, input, 0);
}

/// An element of what a `for` takes: of an `if`'s branches each (`if (c) list else &.{one}`),
/// of a literal written in place, its elements (an `inline for` over a tuple each in turn, a
/// pointer to one a slice of them), else of the resolved input.
fn forElement(self: *Facts, env: ?*const Env, file: Project.FileId, input: Ast.Node.Index, depth: usize) ResolveError!Value {
    if (depth == 16) return .{ .unknown = .budget };
    const tree = &self.project.at(file).file.tree;
    switch (tree.nodeTag(input)) {
        .grouped_expression => return self.forElement(env, file, tree.nodeData(input).node_and_token[0], depth + 1),
        .address_of => {
            var buffer: [2]Ast.Node.Index = undefined;
            const pointed = tree.nodeData(input).node;
            if (tree.fullArrayInit(&buffer, pointed) != null) return self.forElement(env, file, pointed, depth + 1);
        },
        .@"if", .if_simple => {
            const branch = tree.fullIf(input).?; // unreachable: the tag is an `if`'s
            if (branch.payload_token == null and branch.error_token == null) if (branch.ast.else_expr.unwrap()) |otherwise| {
                var each: std.ArrayList(Value) = .empty;
                for ([_]Ast.Node.Index{ branch.ast.then_expr, otherwise }) |taken| {
                    if (never(tree, taken)) continue;
                    try each.append(self.gpa, try self.forElement(env, file, taken, depth + 1));
                }
                return self.choose(each.items);
            };
        },
        else => {},
    }
    // A tuple or array written in place, of no type of its own: each element in turn.
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullArrayInit(&buffer, input)) |list| if (list.ast.type_expr == .none) {
        const each = try self.gpa.alloc(Value, list.ast.elements.len);
        for (list.ast.elements, each) |item, *out| out.* = try self.resolveIn(env, file, item);
        return self.choose(each);
    };
    // A `for` takes arrays, pointers to arrays and slices, never a single item: a resolved
    // pointer input is a slice, whose element is what it points at.
    return self.indexed(try self.resolveIn(env, file, input), {});
}

fn isUnion(self: *const Facts, container: Container) bool {
    const model = &self.project.at(container.file).model;
    const tree = &self.project.at(container.file).file.tree;
    const scope = model.scopes[@backingInt(container.scope)];
    if (scope.kind != .container) return false;
    return tree.tokenTag(tree.nodeMainToken(scope.node)) == .keyword_union;
}

/// Whether two readings of a container a type function made are one type: the same call read
/// with the same bindings (`Line(Plain)` and `Line(Guarded)` are two).
fn sameMaking(a: ?*const Made, b: ?*const Made, depth: usize) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x == y) return true;
    if (depth >= 64) return false;
    if (!std.meta.eql(x.function, y.function) or x.file != y.file or x.call != y.call or x.assumed != y.assumed) return false;
    if (!sameMaking(x.via, y.via, depth + 1)) return false;
    const ex = x.env orelse return y.env == null;
    const ey = y.env orelse return false;
    if (ex == ey) return true;
    if (!std.meta.eql(ex.function, ey.function) or ex.args.len != ey.args.len) return false;
    for (ex.args, ey.args) |one, other| if (!same(one, other, depth + 1)) return false;
    return true;
}

fn same(a: Value, b: Value, depth: usize) bool {
    if (depth == 64) return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .pointer, .array, .optional, .error_union => |inner| switch (b) {
            .pointer, .array, .optional, .error_union => |other| same(inner.*, other.*, depth + 1),
            else => false,
        },
        .container, .instance => |c| switch (b) {
            .container, .instance => |other| c.file == other.file and c.scope == other.scope and sameMaking(c.made_by, other.made_by, depth + 1),
            else => false,
        },
        .primitive => |p| std.mem.eql(u8, p, b.primitive),
        .function => |f| std.meta.eql(f, b.function),
        .alternatives => |each| each.len == b.alternatives.len and for (each, b.alternatives) |x, y| {
            if (!same(x, y, depth + 1)) break false;
        } else true,
        .unknown => false,
        .error_set, .scalar => true,
        .reflected => false,
        .reified => |built| built.value == b.reified.value and same(built.fields.*, b.reified.fields.*, depth + 1),
        .fn_type => |key| std.meta.eql(key, b.fn_type),
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
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    const lowered = record.lowered orelse return null;
    var fn_node = self.project.at(decl.file).file.zir.?.getDeclaration(lowered).src_node;
    if (tree.nodeTag(fn_node) != .fn_decl) fn_node = self.project.at(decl.file).model.parentOf(fn_node) orelse return null;
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
        if (self.project.at(function.file).model.declarations[@backingInt(function.index)].kind != .function) return null;
        return self.template(function);
    }
    const value = try self.resolve(decl.file, returned);
    return value;
}

pub fn declaration(self: *Facts, decl: Decl) ResolveError!Value {
    const model = &self.project.at(decl.file).model;
    const declaration_record = model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    if (declaration_record.kind == .function) return .{ .function = decl };
    if (declaration_record.kind == .parameter) {
        if (try self.settledByCalls(decl)) |position| return self.boundByCallers(decl, position);
        const value = try self.resolve(decl.file, declaration_record.node);
        if (value == .primitive and std.mem.eql(u8, value.primitive, "type")) return .{ .unknown = .comptime_dependent };
        return self.instance(value);
    }
    if (declaration_record.kind == .capture) return self.captured(null, decl);
    if (declaration_record.kind == .field) {
        const field = tree.fullContainerField(declaration_record.node).?;
        if (field.ast.type_expr.unwrap()) |t| return self.instance(try self.resolve(decl.file, t));
        return .{ .unknown = .unsupported };
    }
    if (tree.fullVarDecl(declaration_record.node)) |variable| {
        if (variable.ast.type_node.unwrap()) |t| {
            const type_value = try self.resolve(decl.file, t);
            if (!holdsTypes(type_value)) return self.instance(type_value);
        }
        if (variable.ast.init_node.unwrap()) |value| return self.resolve(decl.file, value);
        if (model.parentOf(declaration_record.node)) |parent| if (tree.nodeTag(parent) == .assign_destructure) return self.destructured(decl.file, parent, declaration_record.node);
    }
    return .{ .unknown = .unsupported };
}

/// The variable `variable` of `const a, const b = value;`: the field of a tuple at its
/// position, or an element of an array.
fn destructured(self: *Facts, file: Project.FileId, whole: Ast.Node.Index, variable: Ast.Node.Index) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
    const full = tree.assignDestructure(whole);
    const position = std.mem.findScalar(Ast.Node.Index, full.ast.variables, variable) orelse return .{ .unknown = .unsupported };
    const value = try self.resolve(file, full.ast.value_expr);
    return self.destructuredAt(value, position);
}

/// Element `position` of a tuple or an array `value` is destructured into.
fn destructuredAt(self: *Facts, value: Value, position: usize) ResolveError!Value {
    switch (value) {
        .array => |each| return each.*,
        .reified => |built| return self.instance(built.fields.*),
        .literal => |literal| {
            const parts = try self.literalParts(literal);
            return if (position < parts.len) parts[position] else .{ .unknown = .unsupported };
        },
        .alternatives => |each| {
            const mapped = try self.gpa.alloc(Value, each.len);
            for (each, mapped) |one, *out| out.* = try self.destructuredAt(one, position);
            return self.choose(mapped);
        },
        .instance => |tuple| {
            const model = &self.project.at(tuple.file).model;
            const source = &self.project.at(tuple.file).file.tree;
            var buffer: [2]Ast.Node.Index = undefined;
            const container = source.fullContainerDecl(&buffer, model.scopes[@backingInt(tuple.scope)].node) orelse return .{ .unknown = .unsupported };
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

/// The values an anonymous literal holds: its fields' or its elements', in order.
pub fn literalParts(self: *Facts, literal: Key) ResolveError![]const Value {
    const tree = &self.project.at(literal.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const nodes = if (tree.fullStructInit(&buffer, literal.node)) |full| full.ast.fields else if (tree.fullArrayInit(&buffer, literal.node)) |full| full.ast.elements else return &.{};
    const parts = try self.gpa.alloc(Value, nodes.len);
    for (nodes, parts) |node, *part| part.* = try self.resolve(literal.file, node);
    return parts;
}

fn memberName(self: *Facts, raw: []const u8) ResolveError![]const u8 {
    return Model.identifier(self.gpa, raw);
}

/// The `T` this run keeps, made with its defaults the first time it is asked for: what a rule
/// computes once for the whole project and reads from each file's check. A type is its own key,
/// so one rule's state is never another's. It lives as long as the run.
pub fn memo(self: *Facts, comptime T: type) ResolveError!*T {
    const key = comptime std.hash.Wyhash.hash(0, @typeName(T));
    const entry = try self.memos.getOrPut(self.gpa, key);
    if (!entry.found_existing) {
        const made = try self.gpa.create(T);
        made.* = .{};
        entry.value_ptr.* = made;
    }
    return @ptrCast(@alignCast(entry.value_ptr.*)); // aegis: internal(A019): the key is this type's own name.
}

/// The member accesses (`x.name`) in the program's files (`program`) that spell `name`, each a
/// `field_access` node: an index built once, for rules that follow one member across files.
pub fn memberUses(self: *Facts, name: []const u8) ResolveError![]const Key {
    if (self.member_uses == null) {
        var index: std.StringHashMapUnmanaged(std.ArrayList(Key)) = .empty;
        for (self.project.sources) |*source| {
            if (!try self.program(source.id)) continue;
            const file = source.id;
            const tree = &source.file.tree;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (tag != .field_access) continue;
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const spelled = try self.memberName(tree.tokenSlice(tree.nodeData(node).node_and_token[1]));
                const entry = try index.getOrPut(self.gpa, spelled);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.gpa, .{ .file = file, .node = node });
            }
        }
        self.member_uses = index;
    }
    return if (self.member_uses.?.get(name)) |list| list.items else &.{};
}

/// A file's own container: the struct the file is.
pub fn rootOf(self: *const Facts, file: Project.FileId) Container {
    return .{ .file = file, .scope = self.project.at(file).model.root() };
}

pub fn member(self: *const Facts, container: Container, name: []const u8) ?Decl {
    const model = &self.project.at(container.file).model;
    if (model.scopes[@backingInt(container.scope)].names.get(name)) |decl| return .{ .file = container.file, .index = decl };
    for (model.declarations, 0..) |decl, i| if (decl.kind == .field and decl.scope == container.scope and std.mem.eql(u8, decl.name, name)) return .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) };
    return null;
}

/// The container whose declaration a declaration literal at `node` names (`.init(...)`): the
/// one its result location gives it, through `try` and the error union or optional around it.
/// A variable's declared type, a returned value's function result, a struct literal's field's
/// type, an assignment's target. Null where nothing written there names one.
pub fn resultContainer(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Container {
    var at = node;
    // Each step is one parent outward; a struct literal's own location is the next.
    for (0..8) |_| {
        const tree = &self.project.at(file).file.tree;
        const model = &self.project.at(file).model;
        const parent = model.parentOf(at) orelse return null;
        switch (tree.nodeTag(parent)) {
            .@"try", .grouped_expression => {
                at = parent;
                continue;
            },
            .@"return" => {
                var function = parent;
                while (tree.nodeTag(function) != .fn_decl) function = model.parentOf(function) orelse return null;
                var buffer: [1]Ast.Node.Index = undefined;
                const proto = tree.fullFnProto(&buffer, tree.nodeData(function).node_and_node[0]) orelse return null;
                return heldContainer(try self.resolve(file, proto.ast.return_type.unwrap() orelse return null));
            },
            .assign => {
                const target, const value = tree.nodeData(parent).node_and_node;
                return if (value == at) heldContainer(try self.resolve(file, target)) else null;
            },
            else => {},
        }
        if (tree.fullVarDecl(parent)) |variable| {
            if (variable.ast.init_node.unwrap() != at) return null;
            return heldContainer(try self.resolve(file, variable.ast.type_node.unwrap() orelse return null));
        }
        var buffer: [2]Ast.Node.Index = undefined;
        const literal = tree.fullStructInit(&buffer, parent) orelse return null;
        // `.name = value`: the token before `=` names the field.
        const first = tree.firstToken(at);
        if (std.mem.findScalar(Ast.Node.Index, literal.ast.fields, at) == null or first < 2) return null;
        if (tree.tokenTag(first - 1) != .equal or tree.tokenTag(first - 2) != .identifier) return null;
        const container = if (literal.ast.type_expr.unwrap()) |kind| heldContainer(try self.resolve(file, kind)) else try self.resultContainer(file, parent);
        const field = self.member(container orelse return null, try self.memberName(tree.tokenSlice(first - 2))) orelse return null;
        const record = self.project.at(field.file).model.declarations[@backingInt(field.index)];
        if (record.kind != .field) return null;
        const declared = (self.project.at(field.file).file.tree.fullContainerField(record.node) orelse return null).ast.type_expr.unwrap() orelse return null;
        return heldContainer(try self.resolve(field.file, declared));
    }
    return null;
}

/// The container a type or a value is, through the error union or optional around it.
fn heldContainer(value: Value) ?Container {
    return switch (value) {
        .container, .instance => |container| container,
        .error_union, .optional => |inner| heldContainer(inner.*),
        else => null,
    };
}

pub fn definition(self: *Facts, file: Project.FileId, node: Ast.Node.Index) ResolveError!?Decl {
    const tree = &self.project.at(file).file.tree;
    if (tree.nodeTag(node) == .identifier or tree.nodeTag(node) == .test_decl) {
        const ref = self.project.at(file).model.reference(node) orelse return null;
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
    const tree = &self.project.at(file).file.tree;
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
    var visited: aegis.bounded.Array(Decl, 128) = .init;
    while (true) {
        for (visited.constItems()) |earlier| if (std.meta.eql(earlier, current)) return null;
        // More aliases than are followed: uncertain, as a cycle is.
        visited.appendSlice(&.{current}) catch return null;
        const record = self.project.at(current.file).model.declarations[@backingInt(current.index)];
        if (record.kind != .variable) return current;
        const tree = &self.project.at(current.file).file.tree;
        const variable = tree.fullVarDecl(record.node).?;
        const expr = variable.ast.init_node.unwrap() orelse return current;
        if (tree.nodeTag(expr) != .identifier and tree.nodeTag(expr) != .field_access) return current;
        current = (try self.definition(current.file, expr)) orelse return null;
    }
}

/// A value of the type `value` names: an instance of a container, and through a pointer,
/// optional, error union or array type, the same wrapper around an instance of its payload
/// (`E!Self` gives an error union whose payload is a `Self`).
fn instance(self: *Facts, value: Value) ResolveError!Value {
    return switch (value) {
        .container => |c| .{ .instance = c },
        .reified => |built| .{ .reified = .{ .fields = built.fields, .value = true } },
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
    // An unknown that a binding would not settle comes first: the choice is unknown for it.
    for (values) |value| if (value == .unknown and value.unknown != .generic) return value;
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
        .reified => |built| .{ .reified = .{ .fields = built.fields } },
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
        .reflected => |r| return (try self.reflectedElement(r, tree, index_node)) orelse .{ .unknown = .unsupported },
        .alternatives => |each| {
            var mapped: std.ArrayList(Value) = .empty;
            for (each) |one| {
                // A function of the choice with no parameter there is one no build of this
                // code takes: Zig refuses the index where it would.
                if (one == .reflected) {
                    try mapped.append(self.gpa, (try self.reflectedElement(one.reflected, tree, index_node)) orelse continue);
                } else try mapped.append(self.gpa, try self.elementOf(one, tree, index_node));
            }
            // No function of the choice has the parameter: Zig compiles this code in no build.
            if (mapped.items.len == 0) return .{ .unknown = .absent };
            return self.choose(mapped.items);
        },
        // A tuple's element: the one a number names, or, for an index known only as the
        // program compiles (an `inline for`'s), one of a literal's parts.
        .reified => |built| return self.instance(built.fields.*),
        .literal, .instance => {
            if (tree.nodeTag(index_node) == .number_literal) {
                const position = std.fmt.parseInt(usize, tree.tokenSlice(tree.nodeMainToken(index_node)), 0) catch return .{ .unknown = .unsupported };
                return self.destructuredAt(base, position);
            }
            if (base == .instance) return .{ .unknown = .comptime_dependent };
            const parts = try self.literalParts(base.literal);
            if (parts.len == 0) return .{ .unknown = .unsupported };
            return self.choose(parts);
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
            const proto = self.prototype(r.of.*) orelse return if (r.of.* == .unknown) r.of.* else unsupported;
            if (std.mem.eql(u8, name, "param_types")) return .{ .reflected = .{ .of = r.of, .at = .params } };
            if (!std.mem.eql(u8, name, "return_type")) return unsupported;
            // `?type`: null for a result that depends on an argument.
            const result = try self.resultOf(proto);
            if (result == .unknown) return result;
            return .{ .optional = try self.boxed(result) };
        },
        .params, .part => return unsupported,
    }
}

/// `param_types[i]` of a reflected function, `?type` as Zig gives it: the parameter's
/// declared type, null (unknown here) for `anytype` or a type that depends on an argument.
/// Null where the function has no parameter `i`.
fn reflectedElement(self: *Facts, r: Reflected, tree: *const Ast, index_node: Ast.Node.Index) ResolveError!?Value {
    if (r.at != .params) return .{ .unknown = .unsupported };
    const proto = self.prototype(r.of.*) orelse return .{ .unknown = .unsupported };
    if (tree.nodeTag(index_node) != .number_literal) return .{ .unknown = .comptime_dependent };
    const position = std.fmt.parseInt(usize, tree.tokenSlice(tree.nodeMainToken(index_node)), 0) catch return .{ .unknown = .unsupported };
    const target_tree = &self.project.at(proto.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, proto.node) orelse return .{ .unknown = .unsupported };
    var it = function.iterate(target_tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at != position) continue;
        const type_expr = param.type_expr orelse return .{ .unknown = .comptime_dependent };
        const value = try self.resolve(proto.file, type_expr);
        if (value == .unknown) return value;
        return .{ .optional = try self.boxed(value) };
    }
    return null;
}

/// The prototype a function or a function type is written with.
fn prototype(self: *const Facts, value: Value) ?Key {
    return switch (value) {
        .function => |decl| .{ .file = decl.file, .node = self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node },
        .fn_type => |key| key,
        else => null,
    };
}

/// The result a prototype declares, as a type, `!T` an error union of it.
fn resultOf(self: *Facts, proto: Key) ResolveError!Value {
    const target_tree = &self.project.at(proto.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, proto.node) orelse return .{ .unknown = .unsupported };
    const result_node = function.ast.return_type.unwrap() orelse return .{ .unknown = .unsupported };
    const result = try self.resolve(proto.file, result_node);
    if (result == .unknown) return result;
    if (Model.inferredErrors(target_tree, result_node)) return .{ .error_union = try self.boxed(result) };
    return result;
}

/// Whether a function takes a parameter only a call settles: `comptime` or `anytype`.
/// Whether the expression `node` names one of `function`'s generic parameters (`comptime`,
/// `anytype` or of type `type`).
fn namesGenericParameter(tree: *const Ast, function: Ast.full.FnProto, node: Ast.Node.Index) bool {
    const first = tree.firstToken(node);
    const last = tree.lastToken(node);
    var it = function.iterate(tree);
    while (it.next()) |param| {
        const generic = param.anytype_ellipsis3 != null or
            (if (param.comptime_noalias) |token| tree.tokenTag(token) == .keyword_comptime else false) or
            (if (param.type_expr) |t| tree.nodeTag(t) == .identifier and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(t)), "type") else false);
        if (!generic) continue;
        const name = tree.tokenSlice(param.name_token orelse continue);
        var token = first;
        while (token <= last) : (token += 1) {
            if (tree.tokenTag(token) == .identifier and std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
        }
    }
    return false;
}

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
    const depth = if (env) |e| e.depth +| 1 else 0;
    if (depth == 8) return null;
    const target_tree = &self.project.at(decl.file).file.tree;
    const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, record.node) orelse return null;
    const result_node = function.ast.return_type.unwrap() orelse return null;
    const returns_type = target_tree.nodeTag(result_node) == .identifier and std.mem.eql(u8, target_tree.tokenSlice(target_tree.nodeMainToken(result_node)), "type");
    // A function of no parameter only a call settles is evaluated only for the type it makes.
    if (!isGeneric(target_tree, function) and !returns_type) return null;
    const tree = &self.project.at(file).file.tree;
    var args: std.ArrayList(Value) = .empty;
    var truths: std.ArrayList(?bool) = .empty;
    // A method called on a value takes that value as its first parameter.
    if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
        const receiver = try self.resolveIn(env, file, tree.nodeData(call.ast.fn_expr).node_and_token[0]);
        const on_value = switch (receiver) {
            .instance => true,
            .pointer => |p| p.* == .instance,
            else => false,
        };
        if (on_value) {
            try args.append(self.gpa, receiver);
            try truths.append(self.gpa, null);
        }
    }
    for (call.ast.params) |arg| {
        try args.append(self.gpa, try self.resolveIn(env, file, arg));
        try truths.append(self.gpa, self.truth(env, file, arg));
    }
    const bound = try self.gpa.create(Env);
    bound.* = .{ .function = decl, .args = args.items, .depth = depth, .truths = truths.items };
    const result_tree = target_tree;
    if (returns_type) {
        const returned = finalReturn(result_tree, &self.project.at(decl.file).model, record) orelse return null;
        // A container is the template's, which the call makes: read by the existing means.
        var container_buffer: [2]Ast.Node.Index = undefined;
        if (result_tree.fullContainerDecl(&container_buffer, returned) != null) return null;
        const value = try self.resolveIn(bound, decl.file, returned);
        return if (value == .unknown) null else value;
    }
    const value = try self.resolveIn(bound, decl.file, result_node);
    if (value == .unknown) return null;
    if (Model.inferredErrors(result_tree, result_node)) return .{ .error_union = try self.boxed(try self.valueOf(value)) };
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
    const tree = &self.project.at(decl.file).file.tree;
    const model = &self.project.at(decl.file).model;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(decl.index)].node) orelse return null;
    var params: [64]Ast.TokenIndex = @splat(0);
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
        const early: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const at = tree.nodeMainToken(early);
        if (at < first or at >= end) continue;
        const operand = tree.nodeData(early).opt_node.unwrap() orelse return null;
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = tree.fullCall(&call_buffer, operand) orelse return null;
        if (tree.nodeTag(call.ast.fn_expr) != .identifier) return null;
        const callee = (model.reference(call.ast.fn_expr) orelse return null).declaration orelse return null;
        if (callee != decl.index or call.ast.params.len != count) return null;
        for (call.ast.params, 0..) |arg, position| {
            const same_parameter = tree.nodeTag(arg) == .identifier and if (model.reference(arg)) |ref| if (ref.declaration) |index| model.declarations[@backingInt(index)].token == params[position] else false else false;
            if (!same_parameter) changed |= @as(u64, 1) << @intCast(position);
        }
    }
    return changed;
}

/// The operand of a function body's one `return`, its final statement.
fn finalReturn(tree: *const Ast, model: *const Model, record: Model.Declaration) ?Ast.Node.Index {
    var fn_node = record.node;
    if (tree.nodeTag(fn_node) != .fn_decl) fn_node = model.parentOf(fn_node) orelse return null;
    if (tree.nodeTag(fn_node) != .fn_decl) return null;
    const body = tree.nodeData(fn_node).node_and_node[1];
    var body_buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&body_buffer, body) orelse return null;
    if (statements.len == 0 or tree.nodeTag(statements[statements.len - 1]) != .@"return") return null;
    const last = statements[statements.len - 1];
    for (tree.firstToken(body)..tree.nodeMainToken(last)) |token| {
        if (tree.tokenTag(@intCast(token)) == .keyword_return) return null;
    }
    return tree.nodeData(last).opt_node.unwrap();
}

/// `node` read with `env`'s bindings: a parameter of the function being read is its argument,
/// a constant declared in its body is what initialises it, and what is built from them is
/// built again; anything else resolves as it does everywhere.
fn resolveIn(self: *Facts, env: ?*const Env, file: Project.FileId, node: Ast.Node.Index) ResolveError!Value {
    const e = env orelse return self.resolve(file, node);
    if (file != e.function.file) return self.resolve(file, node);
    if (self.remaining == 0) return .{ .unknown = .budget };
    self.remaining -= 1;
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return self.resolve(file, node);
            const index = ref.declaration orelse return self.resolve(file, node);
            const record = model.declarations[@backingInt(index)];
            const function_scope = self.scopeNode(e.function);
            if (record.kind == .parameter and model.scopes[@backingInt(record.scope)].node == function_scope) {
                if (self.parameterPosition(file, e.function, record.token)) |position| {
                    if (position < e.args.len) return e.args[position];
                }
                return .{ .unknown = .comptime_dependent };
            }
            if (record.kind == .variable and self.enclosed(file, record.scope, function_scope)) {
                const variable = tree.fullVarDecl(record.node) orelse return self.resolve(file, node);
                if (variable.ast.type_node.unwrap()) |t| {
                    const type_value = try self.resolveIn(env, file, t);
                    if (!holdsTypes(type_value)) return self.instance(type_value);
                }
                if (variable.ast.init_node.unwrap()) |init| return self.resolveIn(env, file, init);
            }
            // A capture of the function's own: what it captures, read with the call's bindings.
            if (record.kind == .capture and self.enclosed(file, record.scope, function_scope)) return self.captured(env, .{ .file = file, .index = index });
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
        .block, .block_semicolon, .block_two, .block_two_semicolon => if (try self.breaks(env, file, node)) |value| return value,
        .array_access => {
            const operands = tree.nodeData(node).node_and_node;
            const base = try self.resolveIn(env, file, operands[0]);
            return self.elementOf(base, tree, operands[1]);
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return self.builtin(env, file, node),
        .address_of => return .{ .pointer = try self.boxed(try self.resolveIn(env, file, tree.nodeData(node).node)) },
        .deref => return self.pointee(try self.resolveIn(env, file, tree.nodeData(node).node), {}),
        .slice_open, .slice, .slice_sentinel => return self.sliced(try self.resolveIn(env, file, tree.fullSlice(node).?.ast.sliced), {}), // unreachable: a slice node is a full slice
        .@"catch" => return self.payload(try self.resolveIn(env, file, tree.nodeData(node).node_and_node[0]), .error_union),
        .@"orelse" => return self.payload(try self.resolveIn(env, file, tree.nodeData(node).node_and_node[0]), .optional),
        .call_one, .call_one_comma, .call, .call_comma => {
            var call_buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&call_buffer, node).?;
            const callee = try self.resolveIn(env, file, call.ast.fn_expr);
            if (callee != .function) return self.callResult(callee, {});
            if (try self.evaluateCall(env, file, call, callee.function)) |value| return value;
            var result = try self.callResult(callee, {});
            // A container a type function makes here is made with this reading's bindings.
            if (result == .container and result.container.symbolic) {
                result.container.made_by = try self.making(.{ .function = callee.function, .file = file, .call = node, .env = e, .assumed = self.assumed });
            }
            return result;
        },
        else => {},
    }
    if (tree.fullPtrType(node)) |ptr| return .{ .pointer = try self.boxed(try self.resolveIn(env, file, ptr.ast.child_type)) };
    if (tree.fullArrayType(node)) |array| return .{ .array = try self.boxed(try self.resolveIn(env, file, array.ast.elem_type)) };
    return self.resolve(file, node);
}

/// Whether `scope` is in the function at `function_node` or in a function declared in it, as a
/// container's that the function returns or calls: what its body reads of the function's comptime
/// parameters is fixed by each binding of the function.
fn enclosed(self: *const Facts, file: Project.FileId, scope: Model.Scope.Id, function_node: Ast.Node.Index) bool {
    const scopes = self.project.at(file).model.scopes;
    var at: ?Model.Scope.Id = scope;
    while (at) |s| : (at = scopes[@backingInt(s)].parent) {
        if (scopes[@backingInt(s)].kind == .function and scopes[@backingInt(s)].node == function_node) return true;
    }
    return false;
}

/// The position of the parameter named by `token` in `function`'s list.
fn parameterPosition(self: *const Facts, file: Project.FileId, function: Decl, token: Ast.TokenIndex) ?usize {
    const tree = &self.project.at(file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, self.project.at(file).model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(tree);
    var position: usize = 0;
    while (it.next()) |param| : (position += 1) if (param.name_token == token) return position;
    return null;
}

/// The function declaring parameter `decl`, and its position, when it is `anytype` or a
/// `comptime` type: a parameter only its calls settle.
fn settledByCalls(self: *Facts, decl: Decl) ResolveError!?usize {
    const model = &self.project.at(decl.file).model;
    const tree = &self.project.at(decl.file).file.tree;
    const record = model.declarations[@backingInt(decl.index)];
    const function = self.functionOf(decl) orelse return null;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
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

/// The type expression a function's parameter is declared with (in its own file), or null for
/// `anytype` or a parameter of no function the file declares.
pub fn parameterTypeNode(self: *const Facts, parameter: Decl) ?Ast.Node.Index {
    const model = &self.project.at(parameter.file).model;
    const tree = &self.project.at(parameter.file).file.tree;
    const function = self.functionOf(parameter) orelse return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, model.declarations[@backingInt(function.index)].node) orelse return null;
    var it = proto.iterate(tree);
    while (it.next()) |param| {
        if (param.name_token != model.declarations[@backingInt(parameter.index)].token) continue;
        return param.type_expr;
    }
    return null;
}

fn functionOf(self: *const Facts, parameter: Decl) ?Decl {
    const model = &self.project.at(parameter.file).model;
    const scope = model.scopes[@backingInt(model.declarations[@backingInt(parameter.index)].scope)];
    if (scope.kind != .function) return null;
    for (model.declarations, 0..) |d, i| {
        if (d.kind != .function) continue;
        const candidate: Decl = .{ .file = parameter.file, .index = @fromBackingInt(@intCast(i)) };
        if (self.scopeNode(candidate) == scope.node) return candidate;
    }
    return null;
}

/// The node a function's scope is recorded at: its declaration with a body, else its prototype.
fn scopeNode(self: *const Facts, function: Decl) Ast.Node.Index {
    const model = &self.project.at(function.file).model;
    const proto = model.declarations[@backingInt(function.index)].node;
    const tree = &self.project.at(function.file).file.tree;
    if (model.parentOf(proto)) |parent| if (tree.nodeTag(parent) == .fn_decl) return parent;
    return proto;
}

/// A generic parameter's value as the project's own calls bind it: the union of their
/// arguments at its position, when every use of the function is a call within the project
/// and its consumers cannot call it by name. Anything else stays unknown.
fn boundByCallers(self: *Facts, parameter: Decl, position: usize) ResolveError!Value {
    const function = self.functionOf(parameter) orelse return .{ .unknown = .comptime_dependent };
    const found = (try self.callArguments(function, position)) orelse return .{ .unknown = .generic };
    // A call that passes something from a module the build does not have is not compiled.
    var values: std.ArrayList(Value) = .empty;
    for (found) |value| if (!absent(value)) try values.append(self.gpa, value);
    // No call the build compiles binds it: whatever binding is made decides.
    if (values.items.len == 0) return .{ .unknown = .generic };
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
    const model = &self.project.at(function.file).model;
    const record = model.declarations[@backingInt(function.index)];
    if (record.public and try self.exportedFunction(function)) return null;
    const name_token = record.token;
    const name = self.project.at(function.file).file.tree.tokenSlice(name_token);
    // std's or aegis's code may call it on a value the program hands it: callers no scan of the
    // program sees.
    if (record.public and try self.calledOutside(name)) return null;
    var values: std.ArrayList(Value) = .empty;
    for (self.project.sources) |*source| {
        const file = &source.file;
        const file_model = &source.model;
        if (file.status != .parsed) continue;
        // A private function is used in its own file only; a file outside the package
        // reaches it only through a module's exported names, which this one is not among.
        const id = source.id;
        const own = id == function.file;
        if (!record.public and !own) continue;
        if (!try self.program(source.id)) continue;
        const tree = &file.tree;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
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
            // A member of a value the program holds at run time, not called, is a field: no
            // need to resolve the value, which may itself be bound by this function's calls.
            if (tag == .field_access and !callee and try self.runtimeValue(id, tree.nodeData(node).node_and_token[0], 0)) continue;
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

/// Whether code outside the program (std's or a known library's) may call a function named
/// `name` of the program's: a call through a member so spelled, or through `@field` with a name
/// that is so spelled or computed, on a receiver that does not resolve to a container of its own
/// (a generic's type parameter, `anytype`), as `HashMap` calls its context's `hash`.
fn calledOutside(self: *Facts, name: []const u8) ResolveError!bool {
    const found = try self.memo(OutsideCalls);
    if (!found.built) {
        found.built = true;
        for (self.project.sources) |*source| {
            if (source.file.status != .parsed or try self.program(source.id)) continue;
            const tree = &source.file.tree;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const parent = source.model.node_parents[i] orelse continue;
                var call_buffer: [1]Ast.Node.Index = undefined;
                const call = tree.fullCall(&call_buffer, parent) orelse continue;
                if (call.ast.fn_expr != node) continue;
                const receiver: Ast.Node.Index, const spelled: []const u8 = switch (tag) {
                    .field_access => .{ tree.nodeData(node).node_and_token[0], tree.tokenSlice(tree.nodeData(node).node_and_token[1]) },
                    .builtin_call_two, .builtin_call_two_comma => blk: {
                        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) continue;
                        var buffer: [2]Ast.Node.Index = undefined;
                        const args = builtinArgs(tree, node, &buffer);
                        if (args.len != 2) continue;
                        if (tree.nodeTag(args[1]) != .string_literal) {
                            try found.computed.append(self.gpa, .{ .file = source.id, .node = args[0] });
                            continue;
                        }
                        break :blk .{ args[0], tree.tokenSlice(tree.nodeMainToken(args[1])) };
                    },
                    else => continue,
                };
                const entry = try found.by_name.getOrPut(self.gpa, std.mem.trim(u8, spelled, "\""));
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.gpa, .{ .file = source.id, .node = receiver });
            }
        }
    }
    if (found.verdicts.get(name)) |known| return known;
    var any = false;
    const named = if (found.by_name.get(name)) |list| list.items else &.{};
    for ([_][]const Key{ named, found.computed.items }) |receivers| for (receivers) |receiver| {
        if (try self.mayBeProgram(try self.resolve(receiver.file, receiver.node))) any = true;
        if (any) break;
    };
    try found.verdicts.put(self.gpa, name, any);
    return any;
}
const OutsideCalls = struct {
    built: bool = false,
    /// Each name called through a member outside the program, with the receivers it is called on.
    by_name: std.StringHashMapUnmanaged(std.ArrayList(Key)) = .empty,
    /// The receivers of calls through `@field` with a computed name: any name.
    computed: std.ArrayList(Key) = .empty,
    verdicts: std.StringHashMapUnmanaged(bool) = .empty,
};

/// Whether a value may be the program's: it does not resolve, or reaches a container of a
/// program file.
fn mayBeProgram(self: *Facts, value: Value) ResolveError!bool {
    return switch (value) {
        .unknown => true,
        .container, .instance => |c| try self.program(c.file),
        .pointer, .array, .optional, .error_union => |inner| self.mayBeProgram(inner.*),
        .alternatives => |each| for (each) |one| {
            if (try self.mayBeProgram(one)) break true;
        } else false,
        else => false,
    };
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
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
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
            const record = model.declarations[@backingInt(ref.declaration orelse return false)];
            switch (record.kind) {
                .parameter => {
                    const function = self.functionOf(.{ .file = file, .index = ref.declaration.? }) orelse return false;
                    var fn_buffer: [1]Ast.Node.Index = undefined;
                    const proto = tree.fullFnProto(&fn_buffer, model.declarations[@backingInt(function.index)].node) orelse return false;
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
        const tree = &self.project.at(decl.file).file.tree;
        const model = &self.project.at(decl.file).model;
        for (tree.nodes.items(.tag), 0..) |tag, i| {
            if (tag != .deref) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
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
        for (self.project.sources) |*source| {
            const file = &source.file;
            const model = &source.model;
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
    const target_tree = &self.project.at(function.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const proto = target_tree.fullFnProto(&fn_buffer, self.project.at(function.file).model.declarations[@backingInt(function.index)].node) orelse return false;
    var count: usize = 0;
    var it = proto.iterate(target_tree);
    while (it.next()) |_| count += 1;
    return call.ast.params.len != count and call.ast.params.len + 1 != count;
}

/// Whether `node` is a path of declarations from a module imported by name: `reactor.Loop`.
fn throughModule(self: *const Facts, file: Project.FileId, node: Ast.Node.Index) bool {
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var at = node;
    while (tree.nodeTag(at) == .field_access) at = tree.nodeData(at).node_and_token[0];
    if (tree.nodeTag(at) != .identifier) return false;
    const ref = model.reference(at) orelse return false;
    const index = ref.declaration orelse return false;
    const record = model.declarations[@backingInt(index)];
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
    const field = model.parentOf(node) orelse return false;
    const full = tree.fullContainerField(field) orelse return false;
    if (full.ast.type_expr.unwrap() != node) return false;
    const container = model.parentOf(field) orelse return false;
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
    const model = &self.project.at(function.file).model;
    var scope = model.declarations[@backingInt(function.index)].scope;
    while (model.scopes[@backingInt(scope)].kind != .container and model.scopes[@backingInt(scope)].kind != .file) scope = model.scopes[@backingInt(scope)].parent orelse return true;
    const set = try self.exportedContainers();
    return set.contains(.{ .file = function.file, .scope = scope });
}

/// Whether `file` is of the package the run lints: selected, or of a package a selected file is.
fn linted(self: *const Facts, file: Project.FileId) bool {
    const input = self.project.at(file).input;
    if (input.selected) return true;
    if (input.package.len == 0) return false;
    for (self.project.sources) |*source| {
        if (source.input.selected and std.mem.eql(u8, source.input.package, input.package)) return true;
    }
    return false;
}

fn exportedContainers(self: *Facts) ResolveError!*const std.AutoHashMapUnmanaged(Container, void) {
    if (self.exported) |*set| return set;
    var set: std.AutoHashMapUnmanaged(Container, void) = .empty;
    var queue: std.ArrayList(Container) = .empty;
    // A module root of the package the run lints: a file imported by a module name rather than
    // a path. A consumer outside this build may call what it exports; a dependency's module is
    // called by nothing this build does not load.
    for (self.project.imports) |edge| {
        if (std.mem.endsWith(u8, edge.spelling, ".zig") or std.mem.eql(u8, edge.spelling, "std") or std.mem.eql(u8, edge.spelling, "builtin")) continue;
        if (!self.linted(edge.target)) continue;
        const root = self.rootOf(edge.target);
        if ((try set.getOrPut(self.gpa, root)).found_existing) continue;
        try queue.append(self.gpa, root);
    }
    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const container = queue.items[next];
        const model = &self.project.at(container.file).model;
        for (model.declarations, 0..) |d, i| {
            if (d.scope != container.scope or !d.public or d.kind != .variable) continue;
            const value = try self.declaration(.{ .file = container.file, .index = @fromBackingInt(@intCast(i)) });
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
    return tree.builtinCallParams(buffer, node) orelse &.{};
}

test "facts aliases cycles and absent module mappings stay unknown" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const A = B; const B = A; const dep = @import(\"missing\");" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const first = project.sources[0].file.tree.fullVarDecl(project.sources[0].model.declarations[0].node).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(Unknown.cycle, (try facts.resolve(project.sources[0].id, first)).unknown);
    const dep = project.sources[0].file.tree.fullVarDecl(project.sources[0].model.declarations[2].node).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(Unknown.missing_mapping, (try facts.resolve(project.sources[0].id, dep)).unknown);
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
        const model = &project.sources[0].model;
        const f = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, "f")) break d;
        } else unreachable; // unreachable: the source declares `f`
        const init = project.sources[0].file.tree.fullVarDecl(f.node).?.ast.init_node.unwrap().?;
        const value = try facts.resolve(project.sources[0].id, init);
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
    const tree = &self.project.at(file).file.tree;
    const model = &self.project.at(file).model;
    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&buffer, node)) |literal| if (literal.ast.type_expr.unwrap()) |t| return self.resolve(file, t);
    const parent = model.parentOf(node) orelse return .{ .unknown = .unsupported };
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
        return self.parameterType(file, parent, call, position);
    }
    var parent_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&parent_buffer, parent) != null) {
        const whole = try self.placeType(file, parent, depth + 1);
        if (whole == .unknown or whole == .scalar) return whole;
        const name = try self.memberName(tree.tokenSlice(Model.initName(tree, node) orelse return .{ .unknown = .unsupported }));
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
            // A `break` with no label leaves the nearest loop; one with a label, the block or
            // loop it names. Each gives that its value.
            const label = tree.nodeData(parent).opt_token_and_opt_node[0].unwrap();
            var at: ?Ast.Node.Index = model.parentOf(parent);
            while (at) |candidate| : (at = model.parentOf(candidate)) {
                const loop = tree.fullWhile(candidate) != null or tree.fullFor(candidate) != null;
                const name = label orelse {
                    if (loop) return self.placeType(file, candidate, depth + 1);
                    continue;
                };
                const tag = tree.nodeTag(candidate);
                // A labeled block's brace follows its label and a colon, as a labeled loop's
                // first token does.
                const start = if (loop) tree.firstToken(candidate) else if (tag == .block or tag == .block_semicolon or tag == .block_two or tag == .block_two_semicolon) tree.nodeMainToken(candidate) else continue;
                if (start >= 2 and tree.tokenTag(start - 1) == .colon and std.mem.eql(u8, tree.tokenSlice(start - 2), tree.tokenSlice(name))) return self.placeType(file, candidate, depth + 1);
            }
            return .{ .unknown = .unsupported };
        },
        // A loop's `else` gives the loop's value.
        .@"for", .for_simple, .@"while", .while_simple, .while_cont => {
            const otherwise = if (tree.fullFor(parent)) |loop| loop.ast.else_expr else tree.fullWhile(parent).?.ast.else_expr; // unreachable: the tag is a loop's
            return if (otherwise.unwrap() == node) self.placeType(file, parent, depth + 1) else .{ .unknown = .unsupported };
        },
        .@"return" => {
            var at: ?Ast.Node.Index = model.parentOf(parent);
            while (at) |candidate| : (at = model.parentOf(candidate)) {
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
fn parameterType(self: *Facts, file: Project.FileId, node: Ast.Node.Index, call: Ast.full.Call, position: usize) ResolveError!Value {
    const tree = &self.project.at(file).file.tree;
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
            if (c.made_by) |m| if (decl.file == c.file and self.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope == c.scope) {
                made = m;
            };
        }
        // A function of a made type called on the type (`Atomic(T).init(x)`): its bindings.
        if (on == .container) if (on.container.made_by) |m| if (decl.file == on.container.file and self.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope == on.container.scope) {
            made = m;
        };
    }
    // A declaration literal's call (`.init(x)`) is a function of the type its place takes.
    if (tree.nodeTag(call.ast.fn_expr) == .enum_literal) switch (try self.placeType(file, node, 1)) {
        .container, .instance => |c| if (c.made_by) |m| if (decl.file == c.file and self.project.at(decl.file).model.declarations[@backingInt(decl.index)].scope == c.scope) {
            made = m;
        },
        else => {},
    };
    const target_tree = &self.project.at(decl.file).file.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;
    const function = target_tree.fullFnProto(&fn_buffer, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].node) orelse return .{ .unknown = .unsupported };
    var it = function.iterate(target_tree);
    var at: usize = 0;
    while (it.next()) |param| : (at += 1) {
        if (at < receiver or at - receiver != position) continue;
        const type_expr = param.type_expr orelse return .scalar;
        if (made) |m| return self.substituted(decl.file, type_expr, m);
        // Written in terms of a `comptime T: type` parameter: the call's argument for it.
        if (try self.written(.{ .file = file, .call = call, .decl = decl, .function = function, .receiver = receiver }, type_expr, 0)) |bound| return bound;
        return self.resolve(decl.file, type_expr);
    }
    return .{ .unknown = .unsupported };
}

test "a container a forwarding type function makes is read with the outer call's bindings" {
    const source =
        \\const Payload = struct { value: u64 };
        \\fn release(p: *Payload) void { _ = p; }
        \\fn Owner(comptime T: type, comptime with_io: bool, comptime cleanup: if (with_io) fn (*T, u8) void else fn (*T) void) type {
        \\    return struct { const Self = @This(); comptime { _ = cleanup; } data: T, pub fn initFrom(source: *T) Self { return .{ .data = source.* }; } pub fn borrowMut(self: *Self) *T { return &self.data; } };
        \\}
        \\pub fn Owned(comptime T: type, comptime cleanup: fn (*T) void) type { return Owner(T, false, cleanup); }
        \\const Held = Owned(Payload, release);
        \\pub fn f(source: *Payload) void { var owner = Held.initFrom(source); const p = owner.borrowMut(); _ = p; }
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    const p = for (model.declarations) |d| {
        if (d.kind == .variable and std.mem.eql(u8, d.name, "p")) break d;
    } else unreachable; // unreachable: the source declares `p`
    const init = project.sources[0].file.tree.fullVarDecl(p.node).?.ast.init_node.unwrap().?;
    const value = try facts.resolve(project.sources[0].id, init);
    try std.testing.expect(value == .pointer);
    try std.testing.expect(value.pointer.* == .instance);
}

test "an error value among a block's breaks makes the others an error union, as null makes them optional" {
    const source =
        \\const Status = struct { entries: []const u8 };
        \\fn status() !Status { return .{ .entries = "" }; }
        \\pub fn f(bare: bool) void {
        \\    const changes = deploy: {
        \\        if (bare) break :deploy error.BareRepository;
        \\        break :deploy status();
        \\    };
        \\    const s = changes catch return;
        \\    const maybe = if (bare) null else status() catch return;
        \\    const either = if (bare) error.Bare else Status{ .entries = "" };
        \\    _ = .{ s, maybe, either };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [3]Value = undefined;
    for ([_][]const u8{ "s", "maybe", "either" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    try std.testing.expect(found[0] == .instance);
    try std.testing.expect(found[1] == .optional and found[1].optional.* == .instance);
    try std.testing.expect(found[2] == .error_union and found[2].error_union.* == .instance);
}

test "@errorReturnTrace and @src give std's own types where the project maps std" {
    const source =
        \\const std = @import("std");
        \\pub fn f() void {
        \\    const here = @src();
        \\    if (@errorReturnTrace()) |trace| {
        \\        const held = trace;
        \\        _ = .{ held, here };
        \\    }
        \\}
    ;
    const lang = "pub const StackTrace = struct { index: usize };\npub const SourceLocation = struct { line: u32 };\n";
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "std/std.zig", .bytes = "pub const lang = @import(\"lang.zig\");\npub const builtin = lang;\n", .selected = false },
        .{ .name = "std/lang.zig", .bytes = lang, .selected = false },
    }, &.{
        .{ .from = 0, .spelling = "std", .target = 1 },
        .{ .from = 1, .spelling = "lang.zig", .target = 2 },
    }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [2]Value = undefined;
    for ([_][]const u8{ "held", "here" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    try std.testing.expect(found[0] == .pointer and found[0].pointer.* == .instance and found[0].pointer.instance.file == project.sources[2].id);
    try std.testing.expect(found[1] == .instance and found[1].instance.file == project.sources[2].id);
}

test "an entry a made container's iterator gives is read with the container's bindings" {
    // The map is a library's, as std's is: its iterator's `next` gives an `Entry` declared
    // beside the iterator in what the call made, not inside it.
    const library =
        \\pub fn Map(comptime K: type, comptime V: type, comptime Ctx: type, comptime load: u64) type {
        \\    return struct {
        \\        const Self = @This();
        \\        comptime { _ = Ctx; _ = load; }
        \\        pub const Entry = struct { key_ptr: *K, value_ptr: *V };
        \\        pub const Iterator = struct { m: *const Self, index: u32 = 0, pub fn next(it: *Iterator) ?Entry { if (it.m.size == 0) return null; const key = &it.m.keys()[it.index]; const value = &it.m.values()[it.index]; return Entry{ .key_ptr = key, .value_ptr = value }; } };
        \\        size: u32 = 0,
        \\        fn keys(self: Self) [*]K { _ = self; return undefined; }
        \\        fn values(self: Self) [*]V { _ = self; return undefined; }
        \\        pub fn iterator(self: *const Self) Iterator { return .{ .m = self }; }
        \\    };
        \\}
        \\fn Context(comptime K: type) type { return struct { pub fn hash(self: @This(), key: K) u64 { _ = self; _ = key; return 0; } }; }
        \\const default_load = 80;
        \\pub fn Auto(comptime K: type, comptime V: type) type { return Map(K, V, Context(K), default_load); }
    ;
    const source =
        \\const lib = @import("lib");
        \\const Id = enum(u32) { a };
        \\const M = lib.Auto(Id, u32);
        \\pub fn f(m: *M) void { var it = m.iterator(); const e = it.next().?; const k = e.key_ptr.*; const i = it; _ = .{ k, i }; }
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "lib/lib.zig", .bytes = library, .selected = false },
    }, &.{.{ .from = 0, .spelling = "lib", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [3]Value = undefined;
    for ([_][]const u8{ "i", "e", "k" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    try std.testing.expect(found[0] == .instance);
    try std.testing.expect(found[1] == .instance);
    try std.testing.expect(found[2] == .instance);
}

test "a made container's method whose result names its own generic parameter is read with each call's argument" {
    const library =
        \\pub fn Untrusted(comptime T: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        value: T,
        \\        pub fn init(value: T) Self { return .{ .value = value }; }
        \\        pub fn parse(self: Self, context: anytype, comptime parser: anytype) Result(parser) { return parser(context, self.value); }
        \\        fn Result(comptime parser: anytype) type {
        \\            const info = @typeInfo(@TypeOf(parser));
        \\            const R = info.@"fn".return_type.?;
        \\            return R;
        \\        }
        \\    };
        \\}
    ;
    const source =
        \\const input = @import("input");
        \\const Header = struct { n: u32 };
        \\const Body = struct { bytes: []const u8 };
        \\fn header(c: u8, bytes: []const u8) error{Bad}!Header { _ = c; _ = bytes; return .{ .n = 1 }; }
        \\fn body(c: u8, bytes: []const u8) error{Bad}!Body { _ = c; return .{ .bytes = bytes }; }
        \\pub fn f(bytes: []const u8) !void {
        \\    const h = try input.Untrusted([]const u8).init(bytes).parse(@as(u8, 0), header);
        \\    const b = try input.Untrusted([]const u8).init(bytes).parse(@as(u8, 0), body);
        \\    _ = .{ h, b };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "input/input.zig", .bytes = library, .selected = false },
    }, &.{.{ .from = 0, .spelling = "input", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const model = &project.sources[0].model;
    var found: [2]Value = undefined;
    for ([_][]const u8{ "h", "b" }, &found) |name, *out| {
        const d = for (model.declarations) |d| {
            if (d.kind == .variable and std.mem.eql(u8, d.name, name)) break d;
        } else unreachable; // unreachable: the source declares each name
        out.* = try facts.resolve(project.sources[0].id, project.sources[0].file.tree.fullVarDecl(d.node).?.ast.init_node.unwrap().?);
    }
    // Each is its own parser's result, not a choice among every call's.
    try std.testing.expect(found[0] == .instance);
    try std.testing.expect(found[1] == .instance);
    try std.testing.expect(found[0].instance.scope != found[1].instance.scope);
}
