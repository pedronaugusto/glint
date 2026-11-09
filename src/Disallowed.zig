//! P006: declarations a project keeps out of its code, decided by what each reference reaches
//! (Governed.zig): a declaration named from a module as programs import it (`std`'s
//! `posix.fdatasync`), from a project input, or an external symbol, which every `extern`
//! declaration of it binds, so the program's own `extern fn fsync` is std's `c.fsync`.
//!
//! The entries come from two places, one engine: the project's own configuration
//! (`Config.disallowed`), whose entries name the packages that own each declaration (in their
//! files it is the designed use), and what a package declares it replaces (`lint_rules`'
//! `.replaces`, PackageRules), which governs every package that imports the declarer, the
//! declarer's own included, save its replacement and what only that reaches, and save the
//! declarer's files none of its modules reach (a benchmark measuring the very call it replaces):
//! those are published to no one. A package's door is every `.with` and every `.door` entry, each
//! read through the aliases that name it: `.door` lists its other functions that do the replaced
//! work themselves, and an entry that reaches no replaced call is a finding, so the list stays
//! what it says.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const PackageRules = @import("PackageRules.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Disallowed = @import("Rule.zig").Config.Disallowed;

pub fn check(self: *Context) Context.Error!void {
    if (!self.config.has(.P006)) return;
    const package = self.project.at(self.file).input.package;
    var targets: std.ArrayList(Governed.Target) = .empty;
    var indexes: std.ArrayList(usize) = .empty;
    for (self.config.disallowed, 0..) |entry, i| {
        if (owned(entry, package)) continue;
        try targets.append(self.allocator, .{ .source = entry.source, .declaration = entry.declaration, .production = entry.scope == .production });
        try indexes.append(self.allocator, i);
    }
    const configured = try Governed.resolve(self, .P006, targets.items, indexes.items);
    const declared = try declaredReplacements(self);
    // Each entry's index says which list it is of: the configuration's, then the declared.
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(self, .P006, configured, &sites);
    try Governed.sites(self, .P006, declared.governed, &sites);
    for (sites.items) |site| {
        if (site.index < self.config.disallowed.len) {
            const entry = self.config.disallowed[site.index];
            try self.atDefinition(.P006, site.token, try self.allocator.print("disallowed declaration: {s}; use {s}", .{ entry.reason, entry.replacement }), site.decl);
            continue;
        }
        // The declaration a package's lint_rules names as replaced is no use of it.
        if (try inLintRules(self, site.node)) continue;
        const replacement = declared.entries[site.index - self.config.disallowed.len];
        switch (try replacementReach(self, site.node, replacement.root, declared.entries)) {
            .exempt => {},
            .judged => try self.atDefinition(.P006, site.token, try self.allocator.print("replaced by {s}: {s}; use {s}", .{ replacement.package, replacement.why, replacement.name }), site.decl),
            .unknown => try self.undecided(.P006, self.project.at(self.file).file.tree.tokenStart(site.token), .unresolved, "a site that may be reached only from the replacements the package declares: a call into it does not resolve, or the budget did not read its users to their end"),
        }
    }
    try deadDoors(self);
}

/// `decl` through the aliases that name it (`pub const syncFile = platform.syncFile;`): what a
/// call of the name reaches.
fn throughAliases(self: *Context, decl: Facts.Decl) Context.Error!Facts.Decl {
    return switch (try self.facts.origin(decl)) {
        .decl => |found| found,
        .none, .unknown => decl,
    };
}

/// Each `.door` entry of this file's `lint_rules` that reaches no call its package replaces: a
/// finding where the list names it, so the list cannot grow into an allowlist; undecided where
/// a call on the way does not resolve, or a governed name does not, or the budget ran out.
fn deadDoors(self: *Context) Context.Error!void {
    const rules = try PackageRules.of(self.facts, self.file);
    if (rules.door.len == 0) return;
    const root = self.file;
    defer self.file = root;
    var door: std.ArrayList(Facts.Decl) = .empty;
    for (rules.door) |entry| if (entry.reference.declaration()) |decl| try door.append(self.allocator, try throughAliases(self, decl));
    var live: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty;
    var seen: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty;
    var pending: std.ArrayList(Facts.Decl) = .empty;
    var uncertain = false;
    const here = PackageRules.Identity.of(self.project, root);
    for (self.project.sources) |*source| {
        if (!PackageRules.Identity.of(self.project, source.id).eql(here) or source.file.status != .parsed) continue;
        self.file = source.id;
        if (try unpublished(self, root)) continue;
        const declared = try declaredReplacements(self);
        var sites: std.ArrayList(Governed.Site) = .empty;
        var unread: std.ArrayList(Governed.Unread) = .empty;
        try Governed.sitesLeaving(self, .P006, declared.governed, &sites, &unread);
        uncertain = uncertain or unread.items.len != 0;
        for (sites.items) |site| {
            if (try inLintRules(self, site.node) or declared.entries[site.index - self.config.disallowed.len].root != root) continue;
            const holder = (try holderOf(self, source.id, site.node)) orelse continue;
            if ((try seen.getOrPut(self.allocator, holder)).found_existing) continue;
            try pending.append(self.allocator, holder);
        }
    }
    self.file = root;
    while (pending.pop()) |at| {
        if (among(door.items, at)) try live.put(self.allocator, at, {});
        if (self.facts.budgetSpent()) {
            uncertain = true;
            break;
        }
        self.facts.remaining -= 1;
        switch (try usersOf(self, at)) {
            .judged => {},
            .unknown => uncertain = true,
            .holders => |holders| for (holders) |user| {
                if ((try seen.getOrPut(self.allocator, user)).found_existing) continue;
                try pending.append(self.allocator, user);
            },
        }
    }
    const tree = &self.project.at(root).file.tree;
    for (rules.door) |entry| {
        const decl = try throughAliases(self, entry.reference.declaration() orelse continue);
        if (live.contains(decl) or entry.file != root) continue;
        if (uncertain) {
            try self.undecided(.P006, tree.tokenStart(tree.firstToken(entry.node)), .unresolved, "a .door entry that may reach no call its package replaces: a call on the way does not resolve, or the budget did not read it to its end");
        } else try self.at(.P006, tree.firstToken(entry.node), "lint_rules: this .door entry reaches no call the package replaces: list only the functions that do the replaced work themselves");
    }
}

/// Whether `package` is one of the entry's owners. An unknown package owns nothing.
fn owned(entry: Disallowed, package: []const u8) bool {
    if (package.len == 0) return false;
    for (entry.owners) |owner| if (std.mem.eql(u8, owner, package)) return true;
    return false;
}

/// A replacement a package declares, as P006 reports it: by the package's name, its reason and
/// its replacement's declaration.
const Declared = struct { package: []const u8, why: []const u8, name: []const u8, with: ?Facts.Decl, root: Project.FileId };

/// What the packages this file's package imports declare they replace, its own package included:
/// each root of the program whose package a file of this file's package imports, read once
/// (PackageRules.of). Their indexes follow the configuration's.
fn declaredReplacements(self: *Context) Context.Error!struct { governed: []const Governed.Governed, entries: []const Declared } {
    const here = PackageRules.Identity.of(self.project, self.file);
    var governed: std.ArrayList(Governed.Governed) = .empty;
    var entries: std.ArrayList(Declared) = .empty;
    for (try PackageRules.roots(self.facts)) |root| {
        if (!importedBy(self.project, root, here)) continue;
        const rules = try PackageRules.of(self.facts, root);
        for (rules.replaces) |replace| {
            const with = if (replace.with.declaration()) |decl| try throughAliases(self, decl) else null;
            const name = if (with) |decl| self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name else "the package's replacement";
            const index = self.config.disallowed.len + entries.items.len;
            if (replace.symbol) |symbol| {
                try governed.append(self.allocator, .{ .target = .{ .declaration = symbol, .production = true }, .index = index, .name = symbol, .decls = &.{}, .symbol = symbol });
            } else {
                // A std declaration that does not resolve is the declarer's problem, reported there.
                const replaced = replace.std orelse continue;
                if (replaced.declarations().len == 0) continue;
                const decl = replaced.declarations()[0];
                const spelled = self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
                const decls = try self.allocator.dupe(Facts.Decl, replaced.declarations());
                try governed.append(self.allocator, .{ .target = .{ .source = "std", .declaration = spelled, .production = true }, .index = index, .name = spelled, .decls = decls, .symbol = null });
            }
            try entries.append(self.allocator, .{ .package = rules.package.name, .why = replace.why, .name = name, .with = with, .root = root });
        }
    }
    return .{ .governed = governed.items, .entries = entries.items };
}

/// Whether `node` lies in this file's own `lint_rules` (PackageRules.Rules.declared).
fn inLintRules(self: *Context, node: Ast.Node.Index) Context.Error!bool {
    const declared = (try PackageRules.of(self.facts, self.file)).declared orelse return false;
    const model = &self.project.at(self.file).model;
    const holder = model.declarations[@backingInt(declared.index)].node;
    var at: ?Ast.Node.Index = node;
    while (at) |each| : (at = model.parentOf(each)) if (each == holder) return true;
    return false;
}

/// Whether `root` governs the package `here`: it is that (named) package's own root, or a file of `here`
/// imports it.
fn importedBy(project: *const Project, root: Project.FileId, here: PackageRules.Identity) bool {
    if (here.name.len != 0 and PackageRules.Identity.of(project, root).eql(here)) return true;
    for (project.imports) |mapping| {
        if (mapping.target != root) continue;
        if (PackageRules.Identity.of(project, mapping.from).eql(here)) return true;
    }
    return false;
}

/// Whether a site in this file is the door's own use: reached only through the replacements the
/// package declares, as a set (main's ruling (b), 11-07): in one of them, or in a function every
/// call of which is in one of them or in another such function, so a helper two replacements
/// share is theirs. A container-level declaration holding the site (a constant, an `extern`) is
/// judged by what references it: each reference in such a function, or in another such
/// declaration. A function handed on as a value, or one a consumer may call by name (public on
/// the package's surface), may be called from anywhere: its site is judged. One whose callers do
/// not all resolve, or that the run's budget does not read to their end, is unknown.
const Reach = enum { exempt, judged, unknown };
fn replacementReach(self: *Context, node: Ast.Node.Index, root: Project.FileId, entries: []const Declared) Context.Error!Reach {
    if (try unpublished(self, root)) return .exempt;
    var door: std.ArrayList(Facts.Decl) = .empty;
    for (entries) |entry| if (entry.root == root) if (entry.with) |with| try door.append(self.allocator, with);
    // The package's own code alone: `.door` says nothing of a file of any other package.
    if (PackageRules.Identity.of(self.project, self.file).eql(PackageRules.Identity.of(self.project, root))) {
        for ((try PackageRules.of(self.facts, root)).door) |entry| if (entry.reference.declaration()) |decl| try door.append(self.allocator, try throughAliases(self, decl));
    }
    if (door.items.len == 0) return .judged;
    const holder = (try holderOf(self, self.file, node)) orelse return .judged;
    return onlyFrom(self, holder, root, door.items);
}

/// The files some module of the run reaches through its imports, for the run.
const Published = struct { reached: ?[]const bool = null };

/// Whether this file is the package's that declares `root`'s replacements and no module reaches
/// it: a benchmark or a development tool the package runs itself. Nothing outside the package
/// compiles it, and a benchmark's baseline exists to measure the very call the package replaces,
/// so no other package's durability or safety rests on what it does. A file a module reaches
/// stays judged, by the door; a file of any other package stays governed wherever it is.
fn unpublished(self: *Context, root: Project.FileId) Context.Error!bool {
    const here = PackageRules.Identity.of(self.project, self.file);
    if (here.name.len == 0 or !PackageRules.Identity.of(self.project, root).eql(here)) return false;
    const memo = try self.facts.memo(Published);
    const reached = memo.reached orelse blk: {
        const marks = try self.facts.gpa.alloc(bool, self.project.sources.len);
        @memset(marks, false);
        var pending: std.ArrayList(Project.FileId) = .empty;
        defer pending.deinit(self.facts.gpa);
        for (try PackageRules.roots(self.facts)) |each| {
            if (marks[@backingInt(each)]) continue;
            marks[@backingInt(each)] = true;
            try pending.append(self.facts.gpa, each);
        }
        while (pending.pop()) |at| for (self.project.imports) |edge| {
            if (edge.from != at or !edge.in.inProgram() or marks[@backingInt(edge.target)]) continue;
            marks[@backingInt(edge.target)] = true;
            try pending.append(self.facts.gpa, edge.target);
        };
        memo.reached = marks;
        break :blk marks;
    };
    return !reached[@backingInt(self.file)];
}

/// What holds `node`: the function whose body it is in, or else the container-level declaration
/// it is written in (a constant, a variable, an `extern` prototype); null at no declaration.
fn holderOf(self: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.Decl {
    if (enclosingFunction(self.project, file, node)) |function| return function;
    const model = &self.project.at(file).model;
    var at: ?Ast.Node.Index = node;
    while (at) |each| : (at = model.parentOf(each)) {
        for (model.declarations, 0..) |decl, i| {
            if (decl.node != each or (decl.kind != .variable and decl.kind != .function)) continue;
            return .{ .file = file, .index = @fromBackingInt(@intCast(i)) };
        }
    }
    return null;
}

/// `onlyFrom`'s answers, per holder and the door's package root, for the run.
const Reached = struct { map: std.AutoHashMapUnmanaged(struct { Facts.Decl, Project.FileId }, Reach) = .empty };

/// Whether every use of `holder`, and every use of what holds those, to the end, is in one of the
/// `door`'s replacements or only reached from them: each holder read once (a seen set, so a cycle
/// adds nothing), each one a resolution of the run's budget.
fn onlyFrom(self: *Context, holder: Facts.Decl, root: Project.FileId, door: []const Facts.Decl) Context.Error!Reach {
    const reached = try self.facts.memo(Reached);
    if (reached.map.get(.{ holder, root })) |known| return known;
    var seen: std.AutoHashMapUnmanaged(Facts.Decl, void) = .empty;
    var pending: std.ArrayList(Facts.Decl) = .empty;
    try seen.put(self.allocator, holder, {});
    try pending.append(self.allocator, holder);
    const answer: Reach = walk: while (pending.pop()) |at| {
        if (among(door, at)) continue;
        if (self.facts.budgetSpent()) break :walk .unknown;
        self.facts.remaining -= 1;
        const users = switch (try usersOf(self, at)) {
            .holders => |found| found,
            .judged => break :walk .judged,
            .unknown => break :walk .unknown,
        };
        // Used by nothing: reached by no replacement either, so its site is judged.
        if (users.len == 0) break :walk .judged;
        for (users) |user| {
            if ((try seen.getOrPut(self.allocator, user)).found_existing) continue;
            try pending.append(self.allocator, user);
        }
    } else .exempt;
    // One the budget cut short is not kept: another asker may read it to its end.
    if (answer != .unknown) try reached.map.put(self.facts.gpa, .{ holder, root }, answer);
    return answer;
}

fn among(door: []const Facts.Decl, decl: Facts.Decl) bool {
    for (door) |each| if (std.meta.eql(each, decl)) return true;
    return false;
}

/// What holds each use of `decl`: for a function, each call's holder (`Facts.programCallSites`);
/// for another container-level declaration, each reference's, in its own file (a private one's
/// only uses). Judged where any code may use it: a function handed on as a value, a public
/// function on the package's surface, a public declaration that is no function, or a use held by
/// no declaration (a test's). Unknown where a call that may be of it does not resolve.
const Users = union(enum) { holders: []const Facts.Decl, judged, unknown };
fn usersOf(self: *Context, decl: Facts.Decl) Context.Error!Users {
    const model = &self.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    if (record.public and try self.facts.onSurface(decl.file, record.scope)) return .judged;
    var found: std.ArrayList(Facts.Decl) = .empty;
    if (record.kind == .function) {
        if (try handedOn(self, decl)) return .judged;
        const calls = (try self.facts.programCallSites(decl)) orelse return .unknown;
        for (calls) |call| try found.append(self.allocator, (try holderOf(self, call.file, call.holder)) orelse return .judged);
        return .{ .holders = found.items };
    }
    if (record.public) return .judged;
    const tree = &self.project.at(decl.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (Facts.accesses.formOf(tag) != .leaf) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != decl.index or tree.nodeMainToken(node) == record.token) continue;
        try found.append(self.allocator, (try holderOf(self, decl.file, node)) orelse return .judged);
    }
    return .{ .holders = found.items };
}

/// Whether the function `decl` is used in its own file other than by a call of it: handed on as a
/// value (`&helper`, `.{ .hook = helper }`), so whoever holds it may call it.
fn handedOn(self: *Context, decl: Facts.Decl) Context.Error!bool {
    const model = &self.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (Facts.accesses.formOf(tag) != .leaf) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != decl.index or tree.nodeMainToken(node) == record.token) continue;
        switch (try Facts.accesses.useOf(self.facts, decl.file, node)) {
            .callee => {},
            else => return true,
        }
    }
    return false;
}

/// The function whose body holds `node`, by its declaration; null at container level.
fn enclosingFunction(project: *const Project, file: Project.FileId, node: Ast.Node.Index) ?Facts.Decl {
    const model = &project.at(file).model;
    const tree = &project.at(file).file.tree;
    var at = model.parentOf(node);
    while (at) |parent| : (at = model.parentOf(parent)) {
        if (tree.nodeTag(parent) != .fn_decl) continue;
        for (model.declarations, 0..) |decl, i| {
            if (decl.kind != .function) continue;
            if (decl.node == parent or model.parentOf(decl.node) == parent) return .{ .file = file, .index = @fromBackingInt(@intCast(i)) };
        }
        return null;
    }
    return null;
}
