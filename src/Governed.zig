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
                if (seen.eql(mapping.target)) break;
            } else try roots.append(self.allocator, mapping.target);
        };
        if (!module) for (self.project.inputs, 0..) |input, i| if (std.mem.eql(u8, input.name, source)) {
            try roots.append(self.allocator, Project.FileId.fromRaw(@intCast(i))); // safe: checked project inventory.
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

/// Every reference in the checked file that reaches a governed declaration, into `out`; a
/// reference spelling a governed name that does not resolve is undecided for `rule`.
pub fn sites(self: *Context, rule: Rule, governed: []const Governed, out: *std.ArrayList(Site)) Context.Error!void {
    if (governed.len == 0) return;
    const tree = &self.project.files[self.file.raw()].tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
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
        for (governed) |g| if (std.mem.eql(u8, g.name, spelled) and !(testing and g.target.production)) {
            applies = true;
        };
        if (!applies) continue;
        const reached = try reach(self, node, tag, spelled, governed);
        const decls = switch (reached) {
            .unknown => |why| {
                try self.unknown(rule, node, why);
                continue;
            },
            .decls => |decls| decls,
        };
        found: for (decls, 0..) |decl, d| for (governed) |g| {
            if (!std.mem.eql(u8, g.name, spelled) or (testing and g.target.production) or !matches(self, g, decl)) continue;
            // `reach` gives a definition first and its origin second: a match on the origin of
            // a different declaration came through the program's alias.
            const alias = d % 2 == 1 and !std.meta.eql(decls[d - 1], decl) and self.project.inputs[decls[d - 1].file.raw()].selected;
            try out.append(self.allocator, .{ .token = site, .node = node, .index = g.index, .decl = decl, .through_alias = alias });
            break :found;
        };
    }
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
    for (roots) |root| try current.append(self.allocator, .{ .file = root, .scope = 0 });
    var found: std.ArrayList(Facts.Decl) = .empty;
    var names = std.mem.splitScalar(u8, path, '.');
    while (names.next()) |name| {
        found.clearRetainingCapacity();
        for (current.items) |container| {
            const decl = self.facts.member(container, name) orelse continue;
            // A field has no `pub`: every field of a container a program reaches is its to name.
            const record = self.project.models[decl.file.raw()].declarations[decl.index];
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
    const tree = &self.project.files[self.file.raw()].tree;
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
    const record = project.models[decl.file.raw()].declarations[decl.index];
    if (record.kind != .function) return null;
    const tree = &project.files[decl.file.raw()].tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const token = (tree.fullFnProto(&buffer, record.node) orelse return null).extern_export_inline_token orelse return null;
    if (tree.tokenTag(token) != .keyword_extern) return null;
    return record.name;
}

/// Whether an identifier is the name of an enum's or union's member written alone
/// (`enum { sync, close }`): the parser gives it as a field's type, but it names the member.
fn memberName(self: *const Context, node: Ast.Node.Index) bool {
    const model = &self.project.models[self.file.raw()];
    const tree = &self.project.files[self.file.raw()].tree;
    const field_node = model.node_parents[@backingInt(node)] orelse return false; // safe: a node index indexes its own tree's parent table.
    const field = tree.fullContainerField(field_node) orelse return false;
    if (!field.ast.tuple_like or field.ast.type_expr.unwrap() != node) return false;
    const container = model.node_parents[@backingInt(field_node)] orelse return false; // safe: a node index indexes its own tree's parent table.
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
    const model = &self.project.models[self.file.raw()];
    const tree = &self.project.files[self.file.raw()].tree;
    const parent = model.node_parents[@backingInt(node)] orelse return false; // safe: a node index indexes its own tree's parent table.
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
    const model = &self.project.models[self.file.raw()];
    const tree = &self.project.files[self.file.raw()].tree;
    const variable = tree.fullVarDecl(parent) orelse return false;
    if (variable.ast.init_node.unwrap() != node) return false;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (tag != .field_access) continue;
        const access: Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: checked AST inventory.
        const receiver = tree.nodeData(access).node_and_token[0];
        if (tree.nodeTag(receiver) != .identifier) continue;
        const ref = model.reference(receiver) orelse continue;
        const index = ref.declaration orelse continue;
        if (model.declarations[index].node == parent) return true;
    }
    return false;
}
