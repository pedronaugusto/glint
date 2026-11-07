//! P006: declarations a project keeps out of its code, decided by what each reference reaches
//! (Governed.zig): a declaration named from a module as programs import it (`std`'s
//! `posix.fdatasync`), from a project input, or an external symbol, which every `extern`
//! declaration of it binds, so the program's own `extern fn fsync` is std's `c.fsync`.
//!
//! The entries come from two places, one engine: the project's own configuration
//! (`Config.disallowed`), whose entries name the packages that own each declaration (in their
//! files it is the designed use), and what a package declares it replaces (`lint_rules`'
//! `.replaces`, PackageRules), which governs every package that imports the declarer, the
//! declarer's own included, save its replacement and what only that reaches.
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
    const governed = try std.mem.concat(self.allocator, Governed.Governed, &.{ configured, declared.governed });
    var sites: std.ArrayList(Governed.Site) = .empty;
    try Governed.sites(self, .P006, governed, &sites);
    for (sites.items) |site| {
        if (site.index < self.config.disallowed.len) {
            const entry = self.config.disallowed[site.index];
            try self.atDefinition(.P006, site.token, try self.allocator.print("disallowed declaration: {s}; use {s}", .{ entry.reason, entry.replacement }), site.decl);
            continue;
        }
        // The declaration a package's lint_rules names as replaced is no use of it.
        if (try inLintRules(self, site.node)) continue;
        const replacement = declared.entries[site.index - self.config.disallowed.len];
        switch (try replacementReach(self, site.node, replacement.with)) {
            .exempt => {},
            .judged => try self.atDefinition(.P006, site.token, try self.allocator.print("replaced by {s}: {s}; use {s}", .{ replacement.package, replacement.why, replacement.name }), site.decl),
            .unknown => try self.undecided(.P006, self.project.at(self.file).file.tree.tokenStart(site.token), .unresolved, "a site whose function may be reached only from the replacement itself: its callers are not all known"),
        }
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
const Declared = struct { package: []const u8, why: []const u8, name: []const u8, with: ?Facts.Decl };

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
            const with = replace.with.declaration();
            const name = if (with) |decl| self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name else "the package's replacement";
            const index = self.config.disallowed.len + entries.items.len;
            if (replace.symbol) |symbol| {
                try governed.append(self.allocator, .{ .target = .{ .declaration = symbol, .production = true }, .index = index, .name = symbol, .decls = &.{}, .symbol = symbol });
            } else {
                // A std declaration that does not resolve is the declarer's problem, reported there.
                const decl = (replace.std orelse continue).declaration() orelse continue;
                const spelled = self.project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
                const decls = try self.allocator.dupe(Facts.Decl, &.{decl});
                try governed.append(self.allocator, .{ .target = .{ .source = "std", .declaration = spelled, .production = true }, .index = index, .name = spelled, .decls = decls, .symbol = null });
            }
            try entries.append(self.allocator, .{ .package = rules.package.name, .why = replace.why, .name = name, .with = with });
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

/// Whether a site in this file is the replacement's own use: in the replacement itself, or in a
/// function only it reaches (every call of it is in the replacement, or in another such function).
/// A function whose callers are not all known (one handed out, or reached deeper than this reads)
/// may be called from anywhere, so its site is judged where the callers are not all the
/// replacement's, and unknown where they cannot be read.
const Reach = enum { exempt, judged, unknown };
fn replacementReach(self: *Context, node: Ast.Node.Index, with: ?Facts.Decl) Context.Error!Reach {
    const replacement = with orelse return .judged;
    const function = enclosingFunction(self.project, self.file, node) orelse return .judged;
    return onlyFrom(self, function, replacement, 0);
}
fn onlyFrom(self: *Context, function: Facts.Decl, replacement: Facts.Decl, depth: usize) Context.Error!Reach {
    if (std.meta.eql(function, replacement)) return .exempt;
    if (depth == 8) return .unknown;
    const calls = (try self.facts.callSites(function)) orelse return .judged;
    if (calls.len == 0) return .judged;
    for (calls) |call| {
        const caller = enclosingFunction(self.project, call.file, call.holder) orelse return .judged;
        switch (try onlyFrom(self, caller, replacement, depth + 1)) {
            .exempt => {},
            .judged => return .judged,
            .unknown => return .unknown,
        }
    }
    return .exempt;
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
