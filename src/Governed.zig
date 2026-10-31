//! Declarations a rule governs, named by a path from a module as programs import it (`std`'s
//! `posix.fdatasync`), from a project input, or as an external symbol, and the sites that reach
//! them. A reference is governed when it resolves to one: an identifier or member access
//! through aliases, a member of every alternative of a per-build choice, `@field` with a written
//! name. Any reference to a declaration spells its name, and an alias spells it where it is
//! made, so only sites spelling a governed name are resolved; one that does not resolve is
//! undecided, never passed. P006 reads a project's policy through it; the aegis pack's danger
//! rules read the std declarations their predicates name.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig").Rule;
const Ast = std.zig.Ast;

/// A declaration as a rule names it. Null `source` names an external function by its symbol:
/// every `extern fn` of that symbol, std's or the program's own, is the one the linker binds.
pub const Target = struct {
    source: ?[]const u8 = null,
    declaration: []const u8,
    /// Test code (tests and test blocks) is not governed.
    production: bool = false,
};

/// One target as this run reads it.
pub const Governed = struct {
    target: Target,
    /// The target's index in what the caller gave.
    index: usize,
    /// The last name of its path, or its symbol: what every reference to it spells.
    name: []const u8,
    decls: []const Facts.Decl,
    symbol: ?[]const u8,
};

/// A reference that reaches a governed declaration.
pub const Site = struct {
    token: Ast.TokenIndex,
    node: Ast.Node.Index,
    /// The target's index in what the caller gave.
    index: usize,
    decl: Facts.Decl,
    /// Reached through an alias the program declares: the alias is a site where it is made.
    through_alias: bool,
    /// The alias is a container's declaration, evaluated as the program compiles: it is no
    /// site where the program runs, so a rule on what runs reads this use as the site.
    alias_declared: bool = false,
};

/// Each target's declarations in this project. A source nothing names, or a path that does not
/// resolve, leaves the run undecided for `rule`: a policy that cannot be read is not a policy
/// that passed. A module no file imports is one nothing here can reach.
pub fn resolve(self: *Context, rule: Rule, targets: []const Target, indexes: []const usize) Context.Error![]const Governed {
    var kept: std.ArrayList(Governed) = .empty;
    for (targets, indexes) |target, index| {
        const g = try kept.addOne(self.allocator);
        const last = if (std.mem.findScalarLast(u8, target.declaration, '.')) |dot| target.declaration[dot + 1 ..] else target.declaration;
        g.* = .{ .target = target, .index = index, .name = last, .decls = &.{}, .symbol = null };
        const source = target.source orelse {
            g.symbol = target.declaration;
            continue;
        };
        // As `@import` reads its operand: a path ending in `.zig` is a file, anything else a module.
        const module = !std.mem.endsWith(u8, source, ".zig");
        var roots: std.ArrayList(Project.FileId) = .empty;
        if (module) for (self.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, source)) {
            for (roots.items) |seen| {
                if (seen == mapping.target) break;
            } else try roots.append(self.allocator, mapping.target);
        };
        if (!module) for (self.project.sources) |*each| if (std.mem.eql(u8, each.input.name, source)) {
            try roots.append(self.allocator, each.id);
        };
        if (roots.items.len == 0) {
            if (!module) try self.undecided(rule, 0, .unresolved, "governed declaration source is not a project input");
            continue;
        }
        g.decls = (try walk(self, roots.items, target.declaration, module)) orelse {
            try self.undecided(rule, 0, .unresolved, try self.allocator.print("governed declaration {s}.{s} could not be resolved", .{ source, target.declaration }));
            continue;
        };
        for (g.decls) |decl| if (externSymbol(self.project, decl)) |symbol| {
            g.symbol = symbol;
        };
    }
    return kept.items;
}

/// The declarations `path` names from module `source`, without reporting: null when no root
/// imports the module or the path does not resolve. For facts that recognize a declaration and
/// leave its absence to the rules that read them.
pub fn declarations(self: *Context, source: []const u8, path: []const u8) Context.Error!?[]const Facts.Decl {
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (self.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, source)) {
        for (roots.items) |seen| {
            if (seen == mapping.target) break;
        } else try roots.append(self.allocator, mapping.target);
    };
    if (roots.items.len == 0) return null;
    return walk(self, roots.items, path, true);
}

/// The declarations at `path` from the files of `package`, every one the run loaded, selected
/// or not: a package's own declaration, where none of its files imports the package by name.
pub fn declarationsOfPackage(self: *Context, package: []const u8, path: []const u8) Context.Error!?[]const Facts.Decl {
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (self.project.sources) |*source| {
        if (std.mem.eql(u8, source.input.package, package)) try roots.append(self.allocator, source.id);
    }
    if (roots.items.len == 0) return null;
    return walk(self, roots.items, path, true);
}

/// Every reference in the checked file that reaches a governed declaration, into `out`; a
/// reference spelling a governed name that does not resolve is undecided for `rule`.
pub fn sites(self: *Context, rule: Rule, governed: []const Governed, out: *std.ArrayList(Site)) Context.Error!void {
    if (governed.len == 0) return;
    // What each target is also called, by an alias whose own site this run does not report.
    const renamed = try self.allocator.alloc([]const []const u8, governed.len);
    for (governed, renamed) |g, *names| {
        var found: std.ArrayList([]const u8) = .empty;
        try aliasNames(self, g.decls, g.symbol, &found);
        names.* = found.items;
    }
    const tree = &self.project.at(self.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const site: Ast.TokenIndex, const spelled: []const u8 = switch (tag) {
            .identifier => blk: {
                if (memberName(self, node)) continue;
                break :blk .{ tree.nodeMainToken(node), try Model.identifier(self.allocator, tree.tokenSlice(tree.nodeMainToken(node))) };
            },
            .field_access => blk: {
                const member = tree.nodeData(node).node_and_token[1];
                break :blk .{ member, try Model.identifier(self.allocator, tree.tokenSlice(member)) };
            },
            .builtin_call_two, .builtin_call_two_comma => blk: {
                if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@field")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = Facts.builtinArgs(tree, node, &buffer);
                if (args.len != 2 or tree.nodeTag(args[1]) != .string_literal) continue;
                const name = std.zig.string_literal.parseAlloc(self.allocator, tree.tokenSlice(tree.nodeMainToken(args[1]))) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                break :blk .{ tree.nodeMainToken(args[1]), name };
            },
            else => continue,
        };
        var applies = false;
        const testing = self.inTest(site);
        for (governed, renamed) |g, names| if (spells(g, names, spelled) and !(testing and g.target.production)) {
            applies = true;
        };
        if (!applies) continue;
        const reached = try reach(self, node, tag, spelled, governed);
        const decls = switch (reached) {
            .unknown => |why| {
                // A method called on a value whose type a generic's binding gives
                // (`s.context.eql(a, b)` in `Interner(T, Context)`) is that type's. Where every
                // governed declaration of that name is a free function, no type has it as a
                // method of its own: the binding reaches one only through an alias its type
                // declares, which is that alias's site.
                if (why == .generic and tag == .field_access and methodCall(self, node) and free(self, governed, spelled)) continue;
                try self.unknown(rule, node, why);
                continue;
            },
            .decls => |decls| decls,
        };
        found: for (decls, 0..) |decl, d| for (governed, renamed) |g, names| {
            if (!spells(g, names, spelled) or (testing and g.target.production) or !matches(self, g, decl)) continue;
            // `reach` gives a definition first and its origin second: a match on the origin of
            // a different declaration came through the program's alias.
            const alias = d % 2 == 1 and !std.meta.eql(decls[d - 1], decl) and self.project.at(decls[d - 1].file).input.selected;
            const declared = alias and switch (self.project.at(decls[d - 1].file).model.scopes[@backingInt(self.project.at(decls[d - 1].file).model.declarations[@backingInt(decls[d - 1].index)].scope)].kind) {
                .file, .container => true,
                else => false,
            };
            try out.append(self.allocator, .{ .token = site, .node = node, .index = g.index, .decl = decl, .through_alias = alias, .alias_declared = declared });
            break :found;
        };
    }
}

/// Whether `spelled` names `g`: its own name, or one of `names`, its aliases'.
fn spells(g: Governed, names: []const []const u8, spelled: []const u8) bool {
    if (std.mem.eql(u8, g.name, spelled)) return true;
    for (names) |name| if (std.mem.eql(u8, name, spelled)) return true;
    return false;
}

/// The names the program's files the run does not select give `decls` (or a function of the
/// extern `symbol`) under another name: `pub const zero = std.crypto.secureZero;`. A use that
/// spells one reaches the declaration, and the alias's own site is not reported in this run,
/// so the use is the site. Each alias is found once, by the declaration its value reaches.
pub fn aliasNames(self: *Context, decls: []const Facts.Decl, symbol: ?[]const u8, out: *std.ArrayList([]const u8)) Context.Error!void {
    const found = try self.facts.memo(Aliases);
    if (!found.built) {
        found.built = true;
        for (self.project.sources) |*source| {
            if (source.input.selected or source.file.status != .parsed or !try self.facts.program(source.id)) continue;
            const tree = &source.file.tree;
            for (source.model.declarations, 0..) |d, i| {
                if (d.kind != .variable) continue;
                const variable = tree.fullVarDecl(d.node) orelse continue;
                const init = variable.ast.init_node.unwrap() orelse continue;
                switch (tree.nodeTag(init)) {
                    .identifier, .field_access => {},
                    .builtin_call_two, .builtin_call_two_comma => if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init)), "@field")) continue,
                    else => continue,
                }
                const decl: Facts.Decl = .{ .file = source.id, .index = @fromBackingInt(@intCast(i)) };
                const origin = (try self.facts.origin(decl)) orelse continue;
                if (std.meta.eql(origin, decl)) continue;
                const entry = try found.by_origin.getOrPut(self.allocator, origin);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.allocator, d.name);
            }
        }
    }
    for (decls) |decl| if (found.by_origin.get(decl)) |names| try out.appendSlice(self.allocator, names.items);
    const wanted = symbol orelse return;
    var each = found.by_origin.iterator();
    while (each.next()) |entry| if (externSymbol(self.project, entry.key_ptr.*)) |own| if (std.mem.eql(u8, own, wanted)) {
        try out.appendSlice(self.allocator, entry.value_ptr.items);
    };
}
const Aliases = struct {
    built: bool = false,
    by_origin: std.AutoHashMapUnmanaged(Facts.Decl, std.ArrayList([]const u8)) = .empty,
};

/// Whether every governed declaration named `name` is a function of a namespace: a container
/// with no fields, so no value's method.
fn free(self: *Context, governed: []const Governed, name: []const u8) bool {
    for (governed) |g| {
        if (!std.mem.eql(u8, g.name, name)) continue;
        for (g.decls) |decl| {
            const model = &self.project.at(decl.file).model;
            const scope = model.declarations[@backingInt(decl.index)].scope;
            if (model.declarations[@backingInt(decl.index)].kind != .function) return false;
            for (model.declarations) |other| if (other.kind == .field and other.scope == scope) return false;
        }
    }
    return true;
}

/// Whether a member access is the callee of a call.
fn methodCall(self: *Context, member: Ast.Node.Index) bool {
    const tree = &self.project.at(self.file).file.tree;
    const parent = self.project.at(self.file).model.parentOf(member) orelse return false;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return false;
    return call.ast.fn_expr == member;
}

fn matches(self: *Context, g: Governed, decl: Facts.Decl) bool {
    for (g.decls) |target| if (std.meta.eql(target, decl)) return true;
    const symbol = g.symbol orelse return false;
    const own = externSymbol(self.project, decl) orelse return false;
    return std.mem.eql(u8, own, symbol);
}

/// The declarations a path names from its roots: through every alternative of a per-build
/// choice (`c.F` is a different struct per target), public ones only from a module. Null when
/// no alternative has it.
fn walk(self: *Context, roots: []const Project.FileId, path: []const u8, public_only: bool) Context.Error!?[]const Facts.Decl {
    var current: std.ArrayList(Facts.Container) = .empty;
    for (roots) |root| try current.append(self.allocator, self.facts.rootOf(root));
    var found: std.ArrayList(Facts.Decl) = .empty;
    var names = std.mem.splitScalar(u8, path, '.');
    while (names.next()) |name| {
        found.clearRetainingCapacity();
        for (current.items) |container| {
            const decl = self.facts.member(container, name) orelse continue;
            // A field has no `pub`: every field of a container a program reaches is its to name.
            const record = self.project.at(decl.file).model.declarations[@backingInt(decl.index)];
            if (public_only and !record.public and record.kind != .field) continue;
            try found.append(self.allocator, (try self.facts.origin(decl)) orelse decl);
        }
        if (found.items.len == 0) return null;
        if (names.peek() == null) break;
        current.clearRetainingCapacity();
        for (found.items) |decl| try containers(self, try self.facts.declaration(decl), &current);
    }
    return try found.toOwnedSlice(self.allocator);
}

/// The containers a value names, each alternative of a choice its own.
fn containers(self: *Context, value: Facts.Value, out: *std.ArrayList(Facts.Container)) Context.Error!void {
    switch (value) {
        .container, .instance => |c| try out.append(self.allocator, c),
        .pointer => |inner| try containers(self, inner.*, out),
        .alternatives => |each| for (each) |one| try containers(self, one, out),
        .function => |decl| if (try self.facts.template(decl)) |made| try containers(self, made, out),
        else => {},
    }
}

const Reached = union(enum) { decls: []const Facts.Decl, unknown: Facts.Unknown };

/// What a site refers to: its declaration through aliases, or the member of each container its
/// receiver may be.
fn reach(self: *Context, node: Ast.Node.Index, tag: Ast.Node.Tag, spelled: []const u8, governed: []const Governed) Context.Error!Reached {
    const definition = if (tag == .identifier or tag == .field_access) try self.facts.definition(self.file, node) else try self.facts.reflected(self.file, node);
    if (definition) |decl| {
        // An alias whose value does not resolve is the program's own declaration: its value is a
        // site of its own.
        const origin = (try self.facts.origin(decl)) orelse decl;
        return .{ .decls = try self.allocator.dupe(Facts.Decl, &.{ decl, origin }) };
    }
    if (tag == .identifier) {
        const value = try self.facts.resolve(self.file, node);
        return if (value == .unknown) .{ .unknown = value.unknown } else .{ .decls = &.{} };
    }
    const tree = &self.project.at(self.file).file.tree;
    const receiver_node = if (tag == .field_access) tree.nodeData(node).node_and_token[0] else blk: {
        var buffer: [2]Ast.Node.Index = undefined;
        break :blk Facts.builtinArgs(tree, node, &buffer)[0];
    };
    const receiver = try self.facts.resolve(self.file, receiver_node);
    if (receiver == .unknown) return if (try refuted(self, node, tag, spelled, governed)) .{ .decls = &.{} } else .{ .unknown = receiver.unknown };
    var options: std.ArrayList(Facts.Container) = .empty;
    try containers(self, receiver, &options);
    var decls: std.ArrayList(Facts.Decl) = .empty;
    for (options.items) |container| {
        const decl = self.facts.member(container, spelled) orelse continue;
        try decls.append(self.allocator, decl);
        try decls.append(self.allocator, (try self.facts.origin(decl)) orelse return .{ .unknown = .cycle });
    }
    return .{ .decls = decls.items };
}

/// The symbol an `extern` function binds: its name.
fn externSymbol(project: *const Project, decl: Facts.Decl) ?[]const u8 {
    const record = project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .function) return null;
    const tree = &project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const token = (tree.fullFnProto(&buffer, record.node) orelse return null).extern_export_inline_token orelse return null;
    if (tree.tokenTag(token) != .keyword_extern) return null;
    return record.name;
}

/// Whether an identifier is the name of an enum's or union's member written alone
/// (`enum { sync, close }`): the parser gives it as a field's type, but it names the member.
fn memberName(self: *const Context, node: Ast.Node.Index) bool {
    const model = &self.project.at(self.file).model;
    const tree = &self.project.at(self.file).file.tree;
    const field_node = model.parentOf(node) orelse return false;
    const field = tree.fullContainerField(field_node) orelse return false;
    if (!field.ast.tuple_like or field.ast.type_expr.unwrap() != node) return false;
    const container = model.parentOf(field_node) orelse return false;
    return switch (tree.tokenTag(tree.nodeMainToken(container))) {
        .keyword_enum, .keyword_union => true,
        else => false,
    };
}

/// Whether no governed declaration spelled `spelled` can be what a member access with an
/// unresolved receiver reaches, by what Zig allows there. Called, every candidate's parameters
/// refuse the arguments, as a method (the receiver first) and as a namespace's function
/// (`RuleContext.accepts`). Not called, its value is a declaration's
/// that the file uses as a receiver of members, which no function and no number has. An
/// external symbol is a function whose parameters are unknown.
fn refuted(self: *Context, node: Ast.Node.Index, tag: Ast.Node.Tag, spelled: []const u8, governed: []const Governed) Context.Error!bool {
    if (tag != .field_access) return false;
    const model = &self.project.at(self.file).model;
    const tree = &self.project.at(self.file).file.tree;
    const parent = model.parentOf(node) orelse return false;
    var call_buffer: [1]Ast.Node.Index = undefined;
    const called: ?Ast.full.Call = if (tree.fullCall(&call_buffer, parent)) |call| (if (call.ast.fn_expr == node) call else null) else null;
    if (called == null and !try usedAsReceiver(self, parent, node)) return false;
    for (governed) |g| {
        if (!std.mem.eql(u8, g.name, spelled)) continue;
        if (g.symbol != null and g.decls.len == 0) {
            if (called != null) return false;
            continue;
        }
        for (g.decls) |decl| {
            const value = try self.facts.declaration(decl);
            if (value != .function and value != .scalar and value != .primitive) return false;
            const call = called orelse continue;
            if (value != .function) return false;
            if (try self.accepts(decl, call, 1) or try self.accepts(decl, call, 0)) return false;
        }
    }
    return true;
}

/// Whether `node` is the value of a declaration that the file uses as a receiver of a member.
fn usedAsReceiver(self: *Context, parent: Ast.Node.Index, node: Ast.Node.Index) Context.Error!bool {
    const model = &self.project.at(self.file).model;
    const tree = &self.project.at(self.file).file.tree;
    const variable = tree.fullVarDecl(parent) orelse return false;
    if (variable.ast.init_node.unwrap() != node) return false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const access: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const receiver = tree.nodeData(access).node_and_token[0];
        if (tree.nodeTag(receiver) != .identifier) continue;
        const ref = model.reference(receiver) orelse continue;
        const index = ref.declaration orelse continue;
        if (model.declarations[@backingInt(index)].node == parent) return true;
    }
    return false;
}
