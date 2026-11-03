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
        if (module) try roots.appendSlice(self.allocator, try moduleRoots(self, source));
        if (!module) for (self.project.sources) |*each| if (std.mem.eql(u8, each.input.name, source)) {
            try roots.append(self.allocator, each.id);
        };
        if (roots.items.len == 0) {
            if (!module) try self.undecided(rule, 0, .unresolved, "governed declaration source is not a project input");
            continue;
        }
        g.decls = switch (try walk(self, roots.items, target.declaration, module)) {
            .decls => |decls| decls,
            .none, .unknown => {
                try self.undecided(rule, 0, .unresolved, try self.allocator.print("governed declaration {s}.{s} could not be resolved", .{ source, target.declaration }));
                continue;
            },
        };
        for (g.decls) |decl| if (externSymbol(self.project, decl)) |symbol| {
            g.symbol = symbol;
        };
    }
    return kept.items;
}

/// What `declarations` finds: the declarations, none (no root imports the module, or the path
/// names nothing), or unknown (the fact budget ran out on the walk, which may have missed one).
pub const Declared = union(enum) {
    decls: []const Facts.Decl,
    none,
    unknown: Facts.Unknown,

    /// The declarations, or null for none and for unknown alike, as every caller read them
    /// before `Declared`: each use drops an unknown. Every use is to become a switch that makes
    /// `.unknown` undecided where it decides; `orNull_test` counts them, the count only falls,
    /// and at none this goes.
    pub fn orNull(self: Declared) ?[]const Facts.Decl {
        return switch (self) {
            .decls => |decls| decls,
            .none, .unknown => null,
        };
    }
};

/// The declarations `path` names from module `source`, without reporting. For facts that
/// recognize a declaration and leave its absence to the rules that read them. The answer is the
/// project's, read once per run for each source and path: a fact asks it at every place it
/// reads, every round.
pub fn declarations(self: *Context, source: []const u8, path: []const u8) Context.Error!Declared {
    // What it keeps in its memo stays for the run.
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
    const memo = try self.facts.memo(Lookups);
    memo.asked += 1;
    if (memo.found.getPtr(source)) |paths| if (paths.get(path)) |known| return known;
    const found = try lookup(self, source, path);
    // A walk the fact budget cut short may have missed a declaration: it is unknown, and asked
    // again.
    if (self.facts.remaining == 0 and found != .decls) return .{ .unknown = .budget };
    const answer = found;
    const paths = try memo.found.getOrPut(self.allocator, source);
    if (!paths.found_existing) {
        paths.key_ptr.* = try self.allocator.dupe(u8, source);
        paths.value_ptr.* = .empty;
    }
    try paths.value_ptr.put(self.allocator, try self.allocator.dupe(u8, path), answer);
    return answer;
}

/// Each `declarations` answer by its source, then its path, and how many times one was asked.
pub const Lookups = struct {
    found: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Declared)) = .empty,
    asked: usize = 0,
};

fn lookup(self: *Context, source: []const u8, path: []const u8) Context.Error!Declared {
    const roots = try moduleRoots(self, source);
    if (roots.len == 0) return .none;
    return walk(self, roots, path, true);
}

/// The files the program's imports of module `source` reach. A governed declaration is a
/// library's, and a library's modules are the program's: a build script's import of the same
/// name is that dependency's build script, as the build runner names it.
fn moduleRoots(self: *Context, source: []const u8) Context.Error![]const Project.FileId {
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (self.project.imports) |mapping| {
        if (!std.mem.eql(u8, mapping.spelling, source) or !mapping.in.inProgram()) continue;
        if (std.mem.findScalar(Project.FileId, roots.items, mapping.target) == null) try roots.append(self.allocator, mapping.target);
    }
    return roots.items;
}

/// The declarations at `path` from the files of `package`, every one the run loaded, selected
/// or not: a package's own declaration, where none of its files imports the package by name.
pub fn declarationsOfPackage(self: *Context, package: []const u8, path: []const u8) Context.Error!Declared {
    var roots: std.ArrayList(Project.FileId) = .empty;
    for (self.project.sources) |*source| {
        if (std.mem.eql(u8, source.input.package, package)) try roots.append(self.allocator, source.id);
    }
    if (roots.items.len == 0) return .none;
    const found = try walk(self, roots.items, path, true);
    return if (self.facts.remaining == 0 and found != .decls) .{ .unknown = .budget } else found;
}

/// Every reference in the checked file that reaches a governed declaration, into `out`; a
/// reference spelling a governed name that does not resolve is undecided for `rule`.
pub fn sites(self: *Context, rule: Rule, governed: []const Governed, out: *std.ArrayList(Site)) Context.Error!void {
    return sitesLeaving(self, rule, governed, out, null);
}

/// A reference spelling a governed name that does not resolve, and why.
pub const Unread = struct { node: Ast.Node.Index, why: Facts.Unknown };

/// `sites`, a reference that does not resolve given to `unread` where there is one, for the
/// caller to judge, instead of undecided.
pub fn sitesLeaving(self: *Context, rule: Rule, governed: []const Governed, out: *std.ArrayList(Site), unread: ?*std.ArrayList(Unread)) Context.Error!void {
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
                if (args.len != 2) continue;
                const named = try self.facts.fieldName(self.file, args[1]);
                switch (named) {
                    .name => |name| break :blk .{ tree.nodeMainToken(node), name },
                    // A name it ranges over or computes: each governed name it may be.
                    .each_of, .names, .computed => {
                        try fieldSites(self, rule, governed, renamed, node, args[0], named, out);
                        continue;
                    },
                }
            },
            // A decl literal (`.fromMilliseconds(ms)`, `.zero`): a member of the type its place
            // gives it.
            .enum_literal => .{ tree.nodeMainToken(node), try Model.identifier(self.allocator, tree.tokenSlice(tree.nodeMainToken(node))) },
            else => {
                // A literal's field (`.{ .nanoseconds = x }`): the member of the type it makes.
                var buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&buffer, node)) |literal| for (literal.ast.fields) |value| {
                    const label = Model.initName(tree, value) orelse continue;
                    try literalSite(self, rule, governed, renamed, node, value, label, out);
                };
                continue;
            },
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
                if (unread) |list| try list.append(self.allocator, .{ .node = node, .why = why }) else try self.unknown(rule, node, why);
                continue;
            },
            .decls => |decls| decls,
        };
        // `reach` gives a definition first and its origin second.
        try append(self, governed, renamed, site, node, spelled, decls, out);
    }
}

/// A literal field's name spelling a governed member: a site where the literal's type has it.
fn literalSite(self: *Context, rule: Rule, governed: []const Governed, renamed: []const []const []const u8, literal: Ast.Node.Index, value: Ast.Node.Index, label: Ast.TokenIndex, out: *std.ArrayList(Site)) Context.Error!void {
    const tree = &self.project.at(self.file).file.tree;
    const spelled = try Model.identifier(self.allocator, tree.tokenSlice(label));
    if (!spelledAny(self, governed, renamed, spelled, label)) return;
    switch (try self.facts.literalDeclaration(self.file, literal, spelled)) {
        .unknown => |why| try self.unknown(rule, value, why),
        .none => {},
        .decl => |decl| switch (try paired(self, decl)) {
            .pair => |pair| try append(self, governed, renamed, label, value, spelled, &pair, out),
            .unknown => |why| try self.unknown(rule, value, why),
        },
    }
}

/// `@field` by a name it ranges over or computes: each governed member its holder has that the
/// name may be is a site; a holder that does not resolve is undecided where a governed name may
/// be named.
fn fieldSites(self: *Context, rule: Rule, governed: []const Governed, renamed: []const []const []const u8, node: Ast.Node.Index, holder: Ast.Node.Index, named: Facts.FieldName, out: *std.ArrayList(Site)) Context.Error!void {
    const tree = &self.project.at(self.file).file.tree;
    const site = tree.nodeMainToken(node);
    const value = try self.facts.resolve(self.file, holder);
    for (governed, renamed) |g, names| {
        for ([_][]const []const u8{ &.{g.name}, names }) |list| for (list) |name| {
            if (!self.facts.mayName(named, name) or (self.inTest(site) and g.target.production)) continue;
            if (value == .unknown) return self.unknown(rule, node, value.unknown);
            var options: std.ArrayList(Facts.Container) = .empty;
            try containers(self, value, &options);
            for (options.items) |container| {
                const decl = self.facts.member(container, name) orelse continue;
                if (named == .computed) return self.undecided(rule, tree.tokenStart(site), .unresolved, "a name @field computes may name a governed declaration");
                switch (try paired(self, decl)) {
                    .pair => |pair| try append(self, governed, renamed, site, node, name, &pair, out),
                    .unknown => |why| return self.unknown(rule, node, why),
                }
            }
        };
    }
}

/// Whether a governed declaration is spelled `spelled` where `site` is.
fn spelledAny(self: *Context, governed: []const Governed, renamed: []const []const []const u8, spelled: []const u8, site: Ast.TokenIndex) bool {
    const testing = self.inTest(site);
    for (governed, renamed) |g, names| if (spells(g, names, spelled) and !(testing and g.target.production)) return true;
    return false;
}

/// The site at `site` for the first governed declaration among `decls`, a definition and its
/// origin in pairs (`reach`).
fn append(self: *Context, governed: []const Governed, renamed: []const []const []const u8, site: Ast.TokenIndex, node: Ast.Node.Index, spelled: []const u8, decls: []const Facts.Decl, out: *std.ArrayList(Site)) Context.Error!void {
    const testing = self.inTest(site);
    for (decls, 0..) |decl, d| for (governed, renamed) |g, names| {
        if (!spells(g, names, spelled) or (testing and g.target.production) or !matches(self, g, decl)) continue;
        // A match on the origin of a different declaration came through the program's alias.
        const alias = d % 2 == 1 and !std.meta.eql(decls[d - 1], decl) and self.project.at(decls[d - 1].file).input.selected;
        const declared = alias and switch (self.project.at(decls[d - 1].file).model.scopes[@backingInt(self.project.at(decls[d - 1].file).model.declarations[@backingInt(decls[d - 1].index)].scope)].kind) {
            .file, .container => true,
            else => false,
        };
        try out.append(self.allocator, .{ .token = site, .node = node, .index = g.index, .decl = decl, .through_alias = alias, .alias_declared = declared });
        return;
    };
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
/// so the use is the site. Each alias is found once, by the declaration its value reaches. One
/// whose value does not resolve reaches what the name it spells last may (`h.sync`, `T.sync`):
/// it is also called so where that name is a declaration's or its aliases' (a use of it is
/// then unknown, `paired`); a name `@field` computes may be any.
pub fn aliasNames(self: *Context, decls: []const Facts.Decl, symbol: ?[]const u8, out: *std.ArrayList([]const u8)) Context.Error!void {
    // What it keeps in its memo stays for the run.
    const rule_memory = self.keep();
    defer self.allocator = rule_memory;
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
                const origin = switch (try self.facts.origin(decl)) {
                    .decl => |reached| reached,
                    .none => continue,
                    .unknown => {
                        try found.unknown.append(self.allocator, .{ .name = d.name, .spells = switch (tree.nodeTag(init)) {
                            .identifier => tree.tokenSlice(tree.nodeMainToken(init)),
                            .field_access => try Model.identifier(self.allocator, tree.tokenSlice(tree.nodeData(init).node_and_token[1])),
                            else => null,
                        } });
                        continue;
                    },
                };
                if (std.meta.eql(origin, decl)) continue;
                const entry = try found.by_origin.getOrPut(self.allocator, origin);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(self.allocator, d.name);
            }
        }
    }
    const start = out.items.len;
    for (decls) |decl| if (found.by_origin.get(decl)) |names| try out.appendSlice(self.allocator, names.items);
    if (symbol) |wanted| {
        var each = found.by_origin.iterator();
        while (each.next()) |entry| if (externSymbol(self.project, entry.key_ptr.*)) |own| if (std.mem.eql(u8, own, wanted)) {
            try out.appendSlice(self.allocator, entry.value_ptr.items);
        };
    }
    // The aliases whose value does not resolve that spell one of these names, or of theirs.
    var spelled: std.ArrayList([]const u8) = .empty;
    for (decls) |decl| try spelled.append(self.allocator, self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name);
    if (symbol) |wanted| try spelled.append(self.allocator, wanted);
    try spelled.appendSlice(self.allocator, out.items[start..]);
    var grew = true;
    while (grew) {
        grew = false;
        for (found.unknown.items) |alias| {
            const named = for (spelled.items) |name| {
                if (std.mem.eql(u8, name, alias.name)) break true;
            } else false;
            if (named) continue;
            const reaches = if (alias.spells) |last| for (spelled.items) |name| {
                if (std.mem.eql(u8, name, last)) break true;
            } else false else true;
            if (!reaches) continue;
            try spelled.append(self.allocator, alias.name);
            try out.append(self.allocator, alias.name);
            grew = true;
        }
    }
}
const Aliases = struct {
    built: bool = false,
    by_origin: std.AutoHashMapUnmanaged(Facts.Decl, std.ArrayList([]const u8)) = .empty,
    /// The aliases whose value does not resolve: each name, and the name its value spells
    /// last (null for `@field`'s, which may be any).
    unknown: std.ArrayList(struct { name: []const u8, spells: ?[]const u8 }) = .empty,
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
/// choice (`c.F` is a different struct per target), public ones only from a module, each through
/// its aliases. None when no alternative has it; unknown where an alias on the way does not
/// resolve.
fn walk(self: *Context, roots: []const Project.FileId, path: []const u8, public_only: bool) Context.Error!Declared {
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
            try found.append(self.allocator, switch (try self.facts.origin(decl)) {
                .decl => |origin| origin,
                .none => decl,
                .unknown => |why| return .{ .unknown = why },
            });
        }
        if (found.items.len == 0) return .none;
        if (names.peek() == null) break;
        current.clearRetainingCapacity();
        for (found.items) |decl| try containers(self, try self.facts.declaration(decl), &current);
    }
    return .{ .decls = try found.toOwnedSlice(self.allocator) };
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
    if (tag == .enum_literal) switch (try self.facts.literalDeclaration(self.file, node, spelled)) {
        .unknown => |why| return .{ .unknown = why },
        .none => return .{ .decls = &.{} },
        .decl => |decl| return switch (try paired(self, decl)) {
            .pair => |pair| .{ .decls = try self.allocator.dupe(Facts.Decl, &pair) },
            .unknown => |why| .{ .unknown = why },
        },
    };
    const definition = if (tag == .identifier or tag == .field_access) try self.facts.definition(self.file, node) else try self.facts.reflected(self.file, node);
    switch (definition) {
        .decl => |decl| return switch (try paired(self, decl)) {
            .pair => |pair| .{ .decls = try self.allocator.dupe(Facts.Decl, &pair) },
            .unknown => |why| .{ .unknown = why },
        },
        // Named by no declaration, or by one not known: read by the value and the receiver below.
        .none, .unknown => {},
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
        switch (try paired(self, decl)) {
            .pair => |pair| try decls.appendSlice(self.allocator, &pair),
            .unknown => |why| return .{ .unknown = why },
        }
    }
    return .{ .decls = decls.items };
}

/// A declaration and its origin, the pair `append` reads. An alias in a selected file whose
/// value does not resolve is its own site: its value is a site of its own where it is written.
/// One in a file the run does not check is unknown: what it names is checked nowhere.
fn paired(self: *Context, decl: Facts.Decl) Context.Error!union(enum) { pair: [2]Facts.Decl, unknown: Facts.Unknown } {
    return switch (try self.facts.origin(decl)) {
        .decl => |origin| .{ .pair = .{ decl, origin } },
        .none => .{ .pair = .{ decl, decl } },
        .unknown => |why| if (self.project.at(decl.file).input.selected) .{ .pair = .{ decl, decl } } else .{ .unknown = why },
    };
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

/// Whether something is so: yes, no, or unknown and why.
pub const Is = union(enum) { yes, no, unknown: Facts.Unknown };

/// Whether `function` is std's declaration at `path` (`mem.Allocator.free`), through aliases.
pub fn isStd(c: *Context, function: Facts.Decl, path: []const u8) Context.Error!Is {
    const decls = switch (try declarations(c, "std", path)) {
        .decls => |decls| decls,
        .none => return .no,
        .unknown => |why| return .{ .unknown = why },
    };
    for (decls) |decl| if (std.meta.eql(decl, function)) return .yes;
    return .no;
}

/// Whether the call at `node` calls std's declaration at `path` (`mem.asBytes`): yes where
/// every function it may call is that one, no where none is. A callee that does not resolve is
/// unknown, unless it cannot be that declaration by what Zig allows: its name (as written)
/// spells neither the declaration's nor an alias's of it, or its parameters refuse the
/// arguments.
pub fn stdCall(c: *Context, node: Ast.Node.Index, path: []const u8) Context.Error!Is {
    return switch (try stdCallees(c, node, path)) {
        .none => .no,
        .every => .yes,
        // One of them only: the call may be it or another.
        .some => .{ .unknown = .unsupported },
        .unknown => |why| .{ .unknown = why },
    };
}

/// Whether the call at `node` may call std's declaration at `path` (`debug.print`): yes where
/// some function it may call is that one, as a per-build choice among them is in the build that
/// takes it; no where none is. A callee that does not resolve is read as `stdCall` reads it.
pub fn mayCallStd(c: *Context, node: Ast.Node.Index, path: []const u8) Context.Error!Is {
    return switch (try stdCallees(c, node, path)) {
        .none => .no,
        .every, .some => .yes,
        .unknown => |why| .{ .unknown = why },
    };
}

/// How many of the functions the call at `node` may call are std's declaration at `path`.
const Callees = union(enum) { none, some, every, unknown: Facts.Unknown };

fn stdCallees(c: *Context, node: Ast.Node.Index, path: []const u8) Context.Error!Callees {
    const call = (try Facts.calls.at(c.facts, c.file, node)) orelse return .none;
    const decls = switch (try declarations(c, "std", path)) {
        .decls => |decls| decls,
        .none => return .none,
        .unknown => |why| return .{ .unknown = why },
    };
    const callees: []const Facts.Decl = switch (call.callee) {
        .function => |function| &.{function},
        .choice => |each| each,
        .any => |why| return if (try notCalled(c, call, decls, path)) .none else .{ .unknown = why },
    };
    var found: usize = 0;
    for (callees) |callee| for (decls) |decl| {
        if (std.meta.eql(decl, callee)) {
            found += 1;
            break;
        }
    };
    if (found == 0) return .none;
    return if (found == callees.len) .every else .some;
}

/// Whether a call whose callee does not resolve cannot call any of `decls`: none takes its
/// arguments, as a method or as a namespace's function; or it calls a member whose name spells
/// neither theirs (`path`'s last) nor an alias's in the program (`aliasNames`). A local's name
/// says nothing: it may hold any of them.
fn notCalled(c: *Context, call: Facts.calls.Call, decls: []const Facts.Decl, path: []const u8) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    var full_buffer: [1]Ast.Node.Index = undefined;
    const full = tree.fullCall(&full_buffer, call.node) orelse return false;
    var takes = false;
    for (decls) |decl| takes = takes or try c.accepts(decl, full, 1) or try c.accepts(decl, full, 0);
    if (!takes) return true;
    if (tree.nodeTag(call.callee_expr) != .field_access) return false;
    const spelled = try Model.identifier(c.allocator, tree.tokenSlice(tree.nodeData(call.callee_expr).node_and_token[1]));
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(c.allocator, if (std.mem.findScalarLast(u8, path, '.')) |dot| path[dot + 1 ..] else path);
    try aliasNames(c, decls, null, &names);
    for (names.items) |name| if (std.mem.eql(u8, name, spelled)) return false;
    return true;
}
