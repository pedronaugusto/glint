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
const Model = @import("Model.zig");
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
    var live: std.ArrayList(Facts.Decl) = .empty;
    var seen: std.ArrayList(Facts.Decl) = .empty;
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
            if (among(seen.items, holder)) continue;
            try seen.append(self.allocator, holder);
            try pending.append(self.allocator, holder);
        }
    }
    self.file = root;
    while (pending.pop()) |at| {
        if (among(door.items, at)) try live.append(self.allocator, at);
        if (self.facts.budgetSpent()) {
            uncertain = true;
            break;
        }
        self.facts.remaining -= 1;
        switch (try usersOf(self, at)) {
            .judged => {},
            .unknown => uncertain = true,
            .holders => |holders| for (holders) |user| {
                if (among(seen.items, user)) continue;
                try seen.append(self.allocator, user);
                try pending.append(self.allocator, user);
            },
        }
    }
    const tree = &self.project.at(root).file.tree;
    for (rules.door) |entry| {
        const decl = try throughAliases(self, entry.reference.declaration() orelse continue);
        if (among(live.items, decl) or entry.file != root) continue;
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
        // The walk's own list is the rule's memory, gone with the check.
        var pending: std.ArrayList(Project.FileId) = .empty;
        for (try PackageRules.roots(self.facts)) |each| {
            if (marks[@backingInt(each)]) continue;
            marks[@backingInt(each)] = true;
            try pending.append(self.allocator, each);
        }
        while (pending.pop()) |at| for (self.project.imports) |edge| {
            if (edge.from != at or !edge.in.inProgram() or marks[@backingInt(edge.target)]) continue;
            marks[@backingInt(edge.target)] = true;
            try pending.append(self.allocator, edge.target);
        };
        memo.reached = marks;
        break :blk marks;
    };
    return !reached[@backingInt(self.file)];
}

/// What holds `node`: the function whose body it is in, or else the container-level declaration
/// it is written in (a constant, a variable, an `extern` prototype); null at no declaration.
fn holderOf(self: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!?Facts.Decl {
    if (self.facts.functionHolding(file, node)) |function| return function;
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
/// only uses), and for a private function handed only to functions of the package that just call
/// it, each hander (`handedOn`). Judged where any code may use it: a function handed on as a value, an exported
/// function, a public function its package's outside can name (`keptInside`), a public declaration that is no function, or a use held by
/// no declaration (a test's). Unknown where a call that may be of it does not resolve.
const Users = union(enum) { holders: []const Facts.Decl, judged, unknown };
fn usersOf(self: *Context, decl: Facts.Decl) Context.Error!Users {
    const model = &self.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    if (record.exported) return .judged;
    if (record.public and try self.facts.onSurface(decl.file, record.scope) and !try keptInside(self, decl, record)) return .judged;
    var found: std.ArrayList(Facts.Decl) = .empty;
    if (record.kind == .function) {
        switch (try handedOn(self, decl)) {
            .no => {},
            .judged => return .judged,
            // Its uses are its own file's, each a call or a hand to a function that calls it:
            // what holds each use is what uses it.
            .by_handers => {
                if (record.public) return .judged;
                const tree = &self.project.at(decl.file).file.tree;
                for (tree.nodes.items(.tag), 0..) |tag, i| {
                    if (Facts.accesses.formOf(tag) != .leaf) continue;
                    const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
                    const ref = model.reference(node) orelse continue;
                    if (ref.declaration != decl.index or tree.nodeMainToken(node) == record.token) continue;
                    if (inTestBlock(self.project, decl.file, node) or try otherLiteral(self, decl, node, ref)) continue;
                    try found.append(self.allocator, (try holderOf(self, decl.file, node)) orelse return .judged);
                }
                return .{ .holders = found.items };
            },
        }
        const calls = (try self.facts.programCallSites(decl)) orelse return .unknown;
        for (calls) |call| {
            if (inTestBlock(self.project, call.file, call.holder)) continue;
            try found.append(self.allocator, (try holderOf(self, call.file, call.holder)) orelse return .judged);
        }
        return .{ .holders = found.items };
    }
    if (record.public) return .judged;
    const tree = &self.project.at(decl.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (Facts.accesses.formOf(tag) != .leaf) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != decl.index or tree.nodeMainToken(node) == record.token) continue;
        if (inTestBlock(self.project, decl.file, node) or try otherLiteral(self, decl, node, ref)) continue;
        try found.append(self.allocator, (try holderOf(self, decl.file, node)) orelse return .judged);
    }
    return .{ .holders = found.items };
}

/// `keptInside`'s reading of each file's namespace, once per run.
const Namespaces = struct { read: std.ArrayList(Namespace) = .empty };
const Namespace = struct { file: Project.FileId, handed: ?[]const Facts.Decl };

/// Whether the top-level function `decl`, `pub` though it is, can be named by no one outside its
/// package: its file's namespace never leaves, and no code of the package hands the function on.
/// A `pub fn` of an internal file is public to the package's other files alone, so its callers
/// are all in the program and the door's walk goes on through them.
fn keptInside(self: *Context, decl: Facts.Decl, record: Model.Declaration) Context.Error!bool {
    if (record.kind != .function or record.exported or record.scope != self.project.at(decl.file).model.root()) return false;
    const memo = try self.facts.memo(Namespaces);
    const handed: ?[]const Facts.Decl = for (memo.read.items) |known| {
        if (known.file == decl.file) break known.handed;
    } else read: {
        const members = try namespaceMembers(self, decl.file);
        try memo.read.append(self.facts.gpa, .{ .file = decl.file, .handed = members });
        break :read members;
    };
    const members: []const Facts.Decl = handed orelse return false;
    for (members) |member| if (member.file == decl.file and member.index == decl.index) return false;
    return true;
}

/// The members of `file`'s namespace the program uses other than by calling them, each by its
/// declaration, where the namespace stays among the files that import it: each `@import` of it
/// (read by the file it resolves to) is read at once as a member (`@import("sys.zig").f()`) or
/// held by a private constant only ever read as one (`sys.f()`), or discarded where it is
/// written (`_ = @import("sys.zig");`). Null where it may leave: a
/// file a module roots, a file that is itself a type (top-level fields, whose `pub` methods any
/// holder of a value calls), a file naming itself (`@This()`), an import whose name is
/// computed, or any other use of an import, which may publish it (`pub const sys = ...`,
/// `const s2 = sys;`, an `if` choosing it).
fn namespaceMembers(self: *Context, file: Project.FileId) Context.Error!?[]const Facts.Decl {
    if (std.mem.findScalar(Project.FileId, try PackageRules.roots(self.facts), file) != null) return null;
    if (namesItself(self.project, file)) return null;
    var handed: std.ArrayList(Facts.Decl) = .empty;
    for (self.project.imports) |edge| {
        if (edge.target != file or !edge.in.inProgram()) continue;
        const model = &self.project.at(edge.from).model;
        const tree = &self.project.at(edge.from).file.tree;
        for (model.import_nodes) |node| {
            const imported: Facts.Container = switch (try self.facts.resolve(edge.from, node)) {
                .container => |k| k,
                // An import no edge of the build resolves is not the edge to this file; one whose
                // name is computed may be.
                .unknown => |why| if (why == .computed_import) return null else continue,
                .alternatives => return null,
                else => continue,
            };
            if (imported.file != file) continue;
            const parent = model.parentOf(node) orelse return null;
            // An import discarded where it is written (`_ = @import("sys.zig");`, a root naming
            // its files to have them analyzed) goes nowhere: no use of the namespace.
            if (try Facts.accesses.useOf(self.facts, edge.from, node) == .discarded) continue;
            if (Facts.accesses.formOf(tree.nodeTag(parent)) == .member) {
                try noteMember(self, imported, edge.from, parent, &handed);
                continue;
            }
            const holder = privateConstantOf(model, tree, parent, node) orelse return null;
            for (tree.nodes.items(.tag), 0..) |tag, i| {
                if (Facts.accesses.formOf(tag) != .leaf) continue;
                const leaf: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const ref = model.reference(leaf) orelse continue;
                if (ref.declaration != holder.id or tree.nodeMainToken(leaf) == holder.token) continue;
                const over = model.parentOf(leaf) orelse return null;
                // `_ = sys;` goes nowhere, as the import discarded does.
                if (try Facts.accesses.useOf(self.facts, edge.from, leaf) == .discarded) continue;
                if (Facts.accesses.formOf(tree.nodeTag(over)) != .member or tree.nodeData(over).node_and_token[0] != leaf) return null;
                try noteMember(self, imported, edge.from, over, &handed);
            }
        }
    }
    return handed.items;
}

/// Adds the declaration of `namespace` the member read at `access` names (`Facts.member`: what
/// Zig finds there by that name), unless the read is a call of it. A member the namespace does
/// not declare is no function of it.
fn noteMember(self: *Context, namespace: Facts.Container, file: Project.FileId, access: Ast.Node.Index, handed: *std.ArrayList(Facts.Decl)) Context.Error!void {
    if (try Facts.accesses.useOf(self.facts, file, access) == .callee) return;
    const tree = &self.project.at(file).file.tree;
    const name = try self.facts.memberName(tree.tokenSlice(tree.nodeData(access).node_and_token[1]));
    try handed.append(self.facts.gpa, self.facts.member(namespace, name) orelse return);
}

/// The private declaration `declaration_node` writes, whose whole value is `value`.
fn privateConstantOf(model: *const Model, tree: *const Ast, declaration_node: Ast.Node.Index, value: Ast.Node.Index) ?Held {
    const written = tree.fullVarDecl(declaration_node) orelse return null;
    if (written.ast.init_node.unwrap() != value) return null;
    for (model.declarations, 0..) |decl, i| {
        if (decl.node != declaration_node or decl.kind != .variable) continue;
        return if (decl.public or decl.exported) null else .{ .id = @fromBackingInt(@intCast(i)), .token = decl.token };
    }
    return null;
}

/// A declaration and the token that names it.
const Held = struct { id: Model.Declaration.Id, token: Ast.TokenIndex };

/// Whether `file` declares a field at its top level or names its own namespace (`@This()` in no
/// container of its own).
fn namesItself(project: *const Project, file: Project.FileId) bool {
    const model = &project.at(file).model;
    const tree = &project.at(file).file.tree;
    for (model.declarations) |decl| if (decl.kind == .field and decl.scope == model.root()) return true;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (Facts.accesses.formOf(tag) != .builtin) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (!Facts.isBuiltin(tree, node, "@This")) continue;
        // In no container the file declares, it names the file.
        var at = model.parentOf(node);
        const inside = while (at) |parent| : (at = model.parentOf(parent)) {
            var buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullContainerDecl(&buffer, parent) != null and model.parentOf(parent) != null) break true;
        } else false;
        if (!inside) return true;
    }
    return false;
}

/// How the function `decl` is used in its own file other than by a call of it. `judged`: handed
/// on as a value (`&helper`, `.{ .hook = helper }`), so whoever holds it may call it.
/// `by_handers`: each such use only hands it to a function outside the package, or to one of the
/// package that does nothing with it but call it (`onlyCalls`), so the function that hands it
/// is the one that uses it. A use in a test block is none: the door speaks for published code
/// only, and a helper only tests reach is judged by nothing.
const HandedOn = enum { no, by_handers, judged };
fn handedOn(self: *Context, decl: Facts.Decl) Context.Error!HandedOn {
    const model = &self.project.at(decl.file).model;
    const record = model.declarations[@backingInt(decl.index)];
    const tree = &self.project.at(decl.file).file.tree;
    var answer: HandedOn = .no;
    for (tree.nodes.items(.tag), 0..) |tag, i| {
        if (Facts.accesses.formOf(tag) != .leaf) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const ref = model.reference(node) orelse continue;
        if (ref.declaration != decl.index or tree.nodeMainToken(node) == record.token) continue;
        if (inTestBlock(self.project, decl.file, node) or try otherLiteral(self, decl, node, ref)) continue;
        switch (try Facts.accesses.useOf(self.facts, decl.file, node)) {
            .callee => {},
            else => {
                var open: std.ArrayList(Facts.Decl) = .empty;
                if (!try onlyCalls(self, decl.file, node, &open)) return .judged;
                answer = .by_handers;
            },
        }
    }
    return answer;
}

/// Whether the use at `node` of a function's value, by its name or by a `comptime` parameter
/// that holds it, leaves it used by the function that holds this use: a call of it (`f(x)`,
/// `@call(m, f, args)`), a hand to a function outside the package (which cannot name a private
/// function: that hand is its only route), or handing it to a `comptime` parameter of a function of the same package, every use of
/// which does the same. A `comptime` parameter is no value at run time: it
/// is stored nowhere a later call could take it from. Judged until proved: a parameter met
/// again while it is being read (`open`) is not proved, and stored, returned or given anywhere
/// else it is not.
fn onlyCalls(self: *Context, file: Project.FileId, node: Ast.Node.Index, open: *std.ArrayList(Facts.Decl)) Context.Error!bool {
    const tree = &self.project.at(file).file.tree;
    switch (try Facts.accesses.useOf(self.facts, file, node)) {
        .callee => return true,
        .builtin_argument => |at| return at.position == 1 and Facts.isBuiltin(tree, at.call, "@call"),
        .argument => |at| {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, at.call) orelse return false;
            const taker: Facts.Decl = switch (try self.facts.resolve(file, call.ast.fn_expr)) {
                .function => |found| found,
                .alternatives => return false,
                else => return false,
            };
            // A method called on a value takes the value first.
            const first: usize = if (Facts.accesses.formOf(tree.nodeTag(call.ast.fn_expr)) != .member) 0 else switch (try self.facts.resolve(file, tree.nodeData(call.ast.fn_expr).node_and_token[0])) {
                .container => 0,
                .instance, .pointer => 1,
                .alternatives => return false,
                else => return false,
            };
            // Code outside the package cannot name a private function: handed there, whatever
            // that code does with it, the hand is its only route, and the hander caused it.
            if (!PackageRules.Identity.of(self.project, taker.file).eql(PackageRules.Identity.of(self.project, file))) return true;
            const parameter = self.facts.parameterAt(taker, at.position + first) orelse return false;
            for (open.items) |known| if (std.meta.eql(known, parameter)) return false;
            try open.append(self.allocator, parameter);
            defer _ = open.pop();
            const taker_tree = &self.project.at(taker.file).file.tree;
            const taker_model = &self.project.at(taker.file).model;
            for (taker_tree.nodes.items(.tag), 0..) |tag, i| {
                if (Facts.accesses.formOf(tag) != .leaf) continue;
                const use: Ast.Node.Index = @fromBackingInt(@intCast(i));
                const ref = taker_model.reference(use) orelse continue;
                if (ref.declaration != parameter.index or ref.unknown == .literal_context) continue;
                if (!self.facts.comptimeParameter(taker.file, use) or !try onlyCalls(self, taker.file, use, open)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Whether the reference `ref` at `node`, which the model reads by its spelling, is an enum
/// literal that cannot name `decl`: its place gives it a type that declares no member so named,
/// or another one. A literal whose type does not resolve may be a decl literal of `decl`'s
/// container (`const op: Op = .direct;`, `.make(x)`): a reference.
fn otherLiteral(self: *Context, decl: Facts.Decl, node: Ast.Node.Index, ref: Model.Reference) Context.Error!bool {
    if (ref.unknown != .literal_context) return false;
    const tree = &self.project.at(decl.file).file.tree;
    const name = try self.facts.memberName(tree.tokenSlice(tree.nodeMainToken(node)));
    return switch (try self.facts.literalDeclaration(decl.file, node, name)) {
        .none => true,
        .decl => |named| !std.meta.eql(named, decl),
        .unknown => false,
    };
}

/// Whether `node` is written in a `test` block.
fn inTestBlock(project: *const Project, file: Project.FileId, node: Ast.Node.Index) bool {
    const model = &project.at(file).model;
    const tree = &project.at(file).file.tree;
    var at = model.parentOf(node);
    while (at) |parent| : (at = model.parentOf(parent)) if (tree.nodeTag(parent) == .test_decl) return true;
    return false;
}
