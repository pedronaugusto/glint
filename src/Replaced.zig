//! The rules a package declares to read `.replaces` (PackageRules, vocabulary version 2): a
//! reference that resolves into an entry's target (a declaration, a container's functions, a
//! field), a builtin it names, an `extern` bound to its symbol, or, for an entry held by value
//! (`.held = .field`), a struct field of its type, outside the declaring package and outside a
//! seam the project declares. The declaring package may use its target only inside the entry's
//! `.door` where it names one, anywhere in its own files where it does not. A ban reports what
//! it cannot resolve where the reference spells a target's name; a hygiene rule reports only
//! what it resolves.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const PackageRules = @import("PackageRules.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Rule = @import("Rule.zig");

/// One entry as the run reads it, with the package that declares it.
pub const Entry = struct { replacement: PackageRules.Replacement, package: PackageRules.Identity };

/// Every `.replaces` entry of the run's packages, each once, for the run.
const Entries = struct { built: bool = false, all: std.ArrayList(Entry) = .empty };

/// The entries naming `rule`, by its id.
pub fn entries(c: *Context, rule: []const u8) Context.Error![]const Entry {
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const found = try c.facts.memo(Entries);
    if (!found.built) {
        found.built = true;
        for (c.project.sources) |*source| {
            if (source.input.kind == .zon) continue;
            if (c.facts.member(c.facts.rootOf(source.id), "lint_rules") == null) continue;
            const rules = try PackageRules.of(c.facts, source.id);
            for (rules.replacements) |replacement| {
                const same = for (found.all.items) |known| {
                    if (known.replacement.file == replacement.file and known.replacement.node == replacement.node) break true;
                } else false;
                if (!same) try found.all.append(c.facts.gpa, .{ .replacement = replacement, .package = rules.package });
            }
        }
    }
    var named: std.ArrayList(Entry) = .empty;
    for (found.all.items) |entry| if (std.mem.eql(u8, entry.replacement.rule, rule)) try named.append(c.allocator, entry);
    return named.items;
}

pub fn check(c: *Context, definition: Rule.Definition) Context.Error!void {
    const declared = definition.declared orelse return;
    const all = try entries(c, definition.name);
    if (all.len == 0) return;
    const here = PackageRules.Identity.of(c.project, c.file);
    // The entries that govern this file: the declaring package's own only where a door narrows them.
    var governed: std.ArrayList(Governed.Governed) = .empty;
    var held: std.ArrayList(usize) = .empty;
    var builtins: std.ArrayList(usize) = .empty;
    for (all, 0..) |entry, i| {
        const replacement = entry.replacement;
        if (entry.package.eql(here) and replacement.door == null) continue;
        if (replacement.held) {
            try held.append(c.allocator, i);
            continue;
        }
        switch (replacement.target) {
            .decl, .members, .field => for (replacement.declarations()) |decl| try governed.append(c.allocator, .{
                .target = .{ .declaration = declName(c.project, decl), .production = true },
                .index = i,
                .name = declName(c.project, decl),
                .decls = try c.allocator.dupe(Facts.Decl, &.{decl}),
                .symbol = null,
            }),
            .symbol => |symbol| try governed.append(c.allocator, .{ .target = .{ .declaration = symbol, .production = true }, .index = i, .name = symbol, .decls = &.{}, .symbol = symbol }),
            .builtin => try builtins.append(c.allocator, i),
            .unresolved => {},
        }
    }
    var sites: std.ArrayList(Governed.Site) = .empty;
    var unread: std.ArrayList(Governed.Unread) = .empty;
    try Governed.sitesLeaving(c, definition.id, governed.items, &sites, &unread);
    for (sites.items) |site| {
        const entry = all[site.index];
        if (!try applies(c, entry, site.node)) continue;
        try c.atDefinition(definition.id, site.token, try message(c, entry), site.decl);
    }
    // Under a ban, a reference spelling a target's name that does not resolve cannot be shown
    // not to be it: a finding. A hygiene rule reports only what it resolves.
    if (declared.kind == .ban) for (unread.items) |missed| {
        const tree = &c.project.at(c.file).file.tree;
        try c.at(definition.id, tree.firstToken(missed.node), try c.allocator.print("a reference spelling a declaration {s} reports does not resolve ({t}), so it cannot be shown to be another", .{ definition.name, missed.why }));
    };
    try builtinSites(c, definition, all, builtins.items);
    try heldSites(c, definition, all, held.items);
}

/// Whether `entry` governs the site at `node`: anywhere outside its package; inside it, only
/// outside the door's functions, and never in the `lint_rules` that declares it.
fn applies(c: *Context, entry: Entry, node: Ast.Node.Index) Context.Error!bool {
    if (!entry.package.eql(PackageRules.Identity.of(c.project, c.file))) return true;
    const holder = holderOf(c, node) orelse return true;
    const record = c.project.at(c.file).model.declarations[@backingInt(holder.index)];
    if (std.mem.eql(u8, record.name, "lint_rules")) return false;
    for (entry.replacement.door orelse return false) |door| {
        const decl = door.declaration() orelse continue;
        if (std.meta.eql(decl, holder)) return false;
    }
    return true;
}

/// The function, or else the container-level declaration, that holds `node`.
fn holderOf(c: *Context, node: Ast.Node.Index) ?Facts.Decl {
    if (c.facts.functionHolding(c.file, node)) |function| return function;
    const model = &c.project.at(c.file).model;
    var at: ?Ast.Node.Index = node;
    while (at) |each| : (at = model.parentOf(each)) {
        for (model.declarations, 0..) |decl, i| {
            if (decl.node != each or (decl.kind != .variable and decl.kind != .function)) continue;
            return .{ .file = c.file, .index = @fromBackingInt(@intCast(i)) };
        }
    }
    return null;
}

/// Each call of a builtin an entry names.
fn builtinSites(c: *Context, definition: Rule.Definition, all: []const Entry, indexes: []const usize) Context.Error!void {
    if (indexes.len == 0) return;
    const tree = &c.project.at(c.file).file.tree;
    for (tree.nodes.items(.tag), 0..) |_, i| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const name = Facts.builtinName(tree, node) orelse continue;
        for (indexes) |index| {
            const entry = all[index];
            if (!std.mem.eql(u8, entry.replacement.target.builtin, name)) continue;
            if (c.inTest(tree.nodeMainToken(node)) or !try applies(c, entry, node)) continue;
            try c.at(definition.id, tree.nodeMainToken(node), try message(c, entry));
        }
    }
}

/// Each struct field whose type is an entry's target held by value (`.held = .field`): the
/// type itself or an optional of it, never a pointer, slice or optional pointer to it.
fn heldSites(c: *Context, definition: Rule.Definition, all: []const Entry, indexes: []const usize) Context.Error!void {
    if (indexes.len == 0) return;
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (model.declarations) |decl| {
        if (decl.kind != .field) continue;
        const field = model.containerField(tree, decl.node) orelse continue;
        const written = field.ast.type_expr.unwrap() orelse continue;
        const value = try c.facts.resolve(c.file, written);
        for (indexes) |index| {
            const entry = all[index];
            for (entry.replacement.declarations()) |target| {
                if (!try heldBy(c, value, target)) continue;
                if (c.inTest(decl.token) or !try applies(c, entry, decl.node)) continue;
                try c.at(definition.id, decl.token, try message(c, entry));
            }
        }
    }
}

/// Whether a field's type `value` holds `target`'s type by value: it, or an optional of it.
fn heldBy(c: *Context, value: Facts.Value, target: Facts.Decl) Context.Error!bool {
    const made = try c.facts.declaration(target);
    const want = switch (made) {
        .container, .instance => |container| container,
        else => return false,
    };
    var current = value;
    while (true) switch (current) {
        .optional => |inner| current = inner.*,
        .container, .instance => |container| return container.file == want.file and container.scope == want.scope,
        .alternatives => |parts| {
            for (parts) |part| if (try heldBy(c, part, target)) return true;
            return false;
        },
        else => return false,
    };
}

/// What a site of `entry` says: who replaces it, why, and with what.
fn message(c: *Context, entry: Entry) Context.Error![]const u8 {
    var answers: std.ArrayList(u8) = .empty;
    for (entry.replacement.with, 0..) |answer, i| {
        if (i != 0) try answers.appendSlice(c.allocator, ", ");
        const decl = answer.declaration() orelse continue;
        try answers.appendSlice(c.allocator, declName(c.project, decl));
    }
    return c.allocator.print("replaced by {s}: {s}; use {s}", .{ entry.package.name, entry.replacement.why, answers.items });
}

fn declName(project: *const Project, decl: Facts.Decl) []const u8 {
    return project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
}
