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
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Report = @import("Report.zig");
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
    try Governed.sitesLeaving(c, governed.items, &sites, &unread);
    const Found = struct { site: Governed.Site, entry: Entry, fix: []const Report.Edit };
    var found: std.ArrayList(Found) = .empty;
    for (sites.items) |site| {
        const entry = all[site.index];
        // A use through an alias the run reports is no second site: the alias is, where it
        // spells the target (review 8, m8).
        if (site.through_alias) continue;
        // The ban means a value of the target is held only through the entry's answer: the
        // target as an argument of that answer (`Secret(T)`) is the answer, and an operand of a
        // comparison of types (`T != U`) makes no value. Neither is a site; a parameter, field,
        // local, result type or call naming the target is.
        if (try answerArgument(c, entry, site.node) or try typeComparison(c, site.node)) continue;
        if (!try applies(c, entry, site.node)) continue;
        const fix = if (entry.replacement.drop_in) |drop_in| try dropInFix(c, entry, drop_in, site, sites.items) else &.{};
        try found.append(c.allocator, .{ .site = site, .entry = entry, .fix = fix });
    }
    // An import whose every use the fixes rewrite goes with them, made once however many carry it.
    var rewritten: std.ArrayList(Report.Edit) = .empty;
    for (found.items) |each| try rewritten.appendSlice(c.allocator, each.fix);
    const unused = try importsLeftUnused(c, rewritten.items);
    for (found.items) |each| {
        const fix = if (each.fix.len == 0 or unused.len == 0) each.fix else try std.mem.concat(c.allocator, Report.Edit, &.{ each.fix, unused });
        try c.atDefinitionFixed(definition.id, each.site.token, try message(c, each.entry), each.site.decl, fix);
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

/// Whether `node` is an argument of a call of one of `entry`'s answers (`Secret(T)`), or names
/// a member of the target that is one (`owner.makeOrError(T.generate, args)`: the target's maker,
/// handed to the answer that makes it in place).
fn answerArgument(c: *Context, entry: Entry, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = node;
    var parent = model.parentOf(at) orelse return false;
    if (tree.nodeTag(parent) == .field_access and tree.nodeData(parent).node_and_token[0] == at) {
        at = parent;
        parent = model.parentOf(at) orelse return false;
    }
    while (tree.nodeTag(parent) == .grouped_expression) {
        at = parent;
        parent = model.parentOf(at) orelse return false;
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return false;
    if (std.mem.findScalar(Ast.Node.Index, call.ast.params, at) == null) return false;
    const callees: []const Facts.Decl = switch ((try Facts.calls.at(c.facts, c.file, parent) orelse return false).callee) {
        .function => |one| &.{one},
        .choice => |each| each,
        .any => return false,
    };
    for (callees) |callee| if (!isAnswer(entry, callee)) return false;
    return callees.len != 0;
}

/// Whether `decl` is one of `entry`'s answers.
fn isAnswer(entry: Entry, decl: Facts.Decl) bool {
    for (entry.replacement.with) |answer| for (answer.declarations()) |each| {
        if (std.meta.eql(each, decl)) return true;
    };
    return false;
}

/// Whether `node`, a type, is an operand of `==` or `!=`: a comparison of types, which holds no
/// value of either.
fn typeComparison(c: *Context, node: Ast.Node.Index) Context.Error!bool {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var at = node;
    var parent = model.parentOf(at) orelse return false;
    while (tree.nodeTag(parent) == .grouped_expression) {
        at = parent;
        parent = model.parentOf(at) orelse return false;
    }
    switch (tree.nodeTag(parent)) {
        .equal_equal, .bang_equal => {},
        else => return false,
    }
    return switch (try c.facts.resolve(c.file, at)) {
        .container => true,
        else => false,
    };
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
/// type itself, or an optional, an array or an error union of it, each holding one or more by
/// value, never a pointer, slice or optional pointer to it.
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

/// Whether a field's type `value` holds `target`'s type by value: it, or an optional, array or
/// error union of it, through any number of them (`[2]?std.Io.File`).
fn heldBy(c: *Context, value: Facts.Value, target: Facts.Decl) Context.Error!bool {
    const made = try c.facts.declaration(target);
    const want = switch (made) {
        .container, .instance => |container| container,
        else => return false,
    };
    var current = value;
    while (true) switch (current) {
        .optional, .array, .error_union => |inner| current = inner.*,
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

/// The fix of a site of an entry with a `.drop_in`: the call written with the answer, and the
/// message argument where the answer takes one, the call's arguments as written. A private
/// container alias of the target (`const assert = std.debug.assert;`), the one site of its
/// uses, is fixed with every call through it, the alias spelling the answer: a use that is no
/// call leaves it unfixed. Where the file reaches the
/// declaring package through no import, the fix adds the one the package's other files make.
/// No fix where the answer cannot be spelled from the file: the declaring package's own code,
/// a file a build script compiles, or a package its module reaches under no one name.
fn dropInFix(c: *Context, entry: Entry, drop_in: PackageRules.Replacement.DropIn, site: Governed.Site, sites: []const Governed.Site) Context.Error![]const Report.Edit {
    if (entry.package.eql(PackageRules.Identity.of(c.project, c.file))) return &.{};
    if (c.project.at(c.file).input.compilations != .program) return &.{};
    const spelled = (try answerSpelling(c, entry, drop_in.answer)) orelse return &.{};
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    var edits: std.ArrayList(Report.Edit) = .empty;
    if (spelled.import) |import| try edits.append(c.allocator, import);
    if (aliasOf(c, site, sites)) |alias| {
        try edits.append(c.allocator, replacing(tree, alias.init, spelled.path));
        const record = model.declarations[@backingInt(alias.decl)];
        for (model.references) |reference| {
            if (reference.declaration != alias.decl or reference.node == record.node) continue;
            const call = callOf(tree, model, reference.node) orelse return &.{};
            if (drop_in.message) try edits.append(c.allocator, (try messageArgument(c, tree, call)) orelse return &.{});
        }
        return edits.items;
    }
    const call = callOf(tree, model, site.node) orelse return &.{};
    try edits.append(c.allocator, replacing(tree, site.node, spelled.path));
    if (drop_in.message) try edits.append(c.allocator, (try messageArgument(c, tree, call)) orelse return &.{});
    return edits.items;
}

/// The removal of each private container-level `@import` declaration of the checked file that
/// is used, and only inside what `edits` replace: the fixes rewrite its last use, and Zig refuses
/// an unused one. Its whole line goes where it holds the declaration alone.
fn importsLeftUnused(c: *Context, edits: []const Report.Edit) Context.Error![]const Report.Edit {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const root = c.facts.rootOf(c.file);
    var out: std.ArrayList(Report.Edit) = .empty;
    for (model.declarations, 0..) |record, i| {
        if (record.kind != .variable or record.scope != root.scope or record.public) continue;
        if (importSpelling(c, tree, record.node) == null) continue;
        const id: Model.Declaration.Id = @fromBackingInt(@intCast(i));
        var used = false;
        const kept = for (model.references) |reference| {
            if (reference.declaration != id or reference.node == record.node) continue;
            used = true;
            const at = tree.tokenToSpan(tree.firstToken(reference.node)).start;
            const inside = for (edits) |edit| {
                if (edit.start < edit.end and edit.start <= at and at < edit.end) break true;
            } else false;
            if (!inside) break true;
        } else false;
        if (kept or !used) continue;
        try out.append(c.allocator, wholeLine(tree, record.node));
    }
    return out.items;
}

/// The edit removing a container-level declaration: its line, newline included, where the line
/// holds nothing else; else the declaration's own tokens.
fn wholeLine(tree: *const Ast, node: Ast.Node.Index) Report.Edit {
    const bytes = tree.source;
    var start = tree.tokenToSpan(tree.firstToken(node)).start;
    // The `;` after a variable declaration is its last token's next.
    var end = tree.tokenToSpan(tree.lastToken(node) + 1).end;
    var line_start = start;
    while (line_start > 0 and (bytes[line_start - 1] == ' ' or bytes[line_start - 1] == '\t')) line_start -= 1;
    var line_end = end;
    while (line_end < bytes.len and (bytes[line_end] == ' ' or bytes[line_end] == '\t')) line_end += 1;
    if ((line_start == 0 or bytes[line_start - 1] == '\n') and (line_end == bytes.len or bytes[line_end] == '\n')) {
        start = line_start;
        end = if (line_end < bytes.len) line_end + 1 else line_end;
    }
    return .{ .start = start, .end = end, .text = "" };
}

/// How the checked file spells an answer: a path from an import of the declaring package, and
/// the import the fix adds where the file makes none.
const Spelled = struct { path: []const u8, import: ?Report.Edit };

fn answerSpelling(c: *Context, entry: Entry, answer: Facts.Decl) Context.Error!?Spelled {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const root = c.facts.rootOf(c.file);
    // An import the file makes, of a file of the package the answer is reached from.
    for (model.declarations) |record| {
        if (record.kind != .variable or record.scope != root.scope) continue;
        const spelling = importSpelling(c, tree, record.node) orelse continue;
        const target = c.project.imported(c.file, spelling) orelse continue;
        if (!entry.package.eql(PackageRules.Identity.of(c.project, target))) continue;
        const inner = (try pathTo(c, c.facts.rootOf(target), answer, 0)) orelse continue;
        return .{ .path = try c.allocator.print("{s}.{s}", .{ record.name, inner }), .import = null };
    }
    // The one module name the package's other files of this program import it by.
    const here = PackageRules.Identity.of(c.project, c.file);
    var found: ?struct { spelling: []const u8, path: []const u8 } = null;
    for (c.project.imports) |edge| {
        if (!edge.in.inProgram() or std.mem.endsWith(u8, edge.spelling, ".zig") or std.mem.endsWith(u8, edge.spelling, ".zon")) continue;
        if (!here.eql(PackageRules.Identity.of(c.project, edge.from)) or !entry.package.eql(PackageRules.Identity.of(c.project, edge.target))) continue;
        const inner = (try pathTo(c, c.facts.rootOf(edge.target), answer, 0)) orelse continue;
        if (found) |known| {
            if (!std.mem.eql(u8, known.spelling, edge.spelling)) return null;
        } else found = .{ .spelling = edge.spelling, .path = inner };
    }
    const chosen = found orelse return null;
    if (!std.zig.isValidId(chosen.spelling)) return null;
    // A name the file declares anywhere would shadow, or be shadowed by, the import.
    for (model.declarations) |record| if (std.mem.eql(u8, record.name, chosen.spelling)) return null;
    return .{
        .path = try c.allocator.print("{s}.{s}", .{ chosen.spelling, chosen.path }),
        .import = .{ .start = importOffset(c, tree, model, root), .end = importOffset(c, tree, model, root), .text = try c.allocator.print("const {s} = @import(\"{s}\");\n", .{ chosen.spelling, chosen.spelling }) },
    };
}

/// The module or file `@import` names where `node` declares `const x = @import("...")`.
fn importSpelling(c: *Context, tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    const variable = tree.fullVarDecl(node) orelse return null;
    const init = variable.ast.init_node.unwrap() orelse return null;
    if (!std.mem.eql(u8, Facts.builtinName(tree, init) orelse return null, "@import")) return null;
    var buffer: [2]Ast.Node.Index = undefined;
    const arguments = tree.builtinCallParams(&buffer, init) orelse return null;
    if (arguments.len != 1 or tree.nodeTag(arguments[0]) != .string_literal) return null;
    return std.zig.string_literal.parseAlloc(c.allocator, tree.tokenSlice(tree.nodeMainToken(arguments[0]))) catch null;
}

/// Where an added import goes: the line after the file's last container-level import, or
/// after its leading `//!` comment lines where it makes none.
fn importOffset(c: *Context, tree: *const Ast, model: *const Model, root: Facts.Container) u32 {
    var after: ?u32 = null;
    for (model.declarations) |record| {
        if (record.kind != .variable or record.scope != root.scope) continue;
        if (importSpelling(c, tree, record.node) == null) continue;
        const end = tree.tokenToSpan(tree.lastToken(record.node) + 1).end;
        if (after == null or end > after.?) after = end;
    }
    const bytes = tree.source;
    var at: usize = after orelse 0;
    if (after == null) {
        while (std.mem.startsWith(u8, bytes[at..], "//!")) at = if (std.mem.findScalarPos(u8, bytes, at, '\n')) |newline| newline + 1 else bytes.len;
        return @intCast(at);
    }
    return @intCast(if (std.mem.findScalarPos(u8, bytes, at, '\n')) |newline| newline + 1 else bytes.len);
}

/// The public path from `container` to `answer`, through public declarations whose value is a
/// container, at most three deep: `assert.invariant`.
fn pathTo(c: *Context, container: Facts.Container, answer: Facts.Decl, depth: u8) Context.Error!?[]const u8 {
    const model = &c.project.at(container.file).model;
    for (model.declarations, 0..) |record, i| {
        if (record.scope != container.scope or !record.public) continue;
        const decl: Facts.Decl = .{ .file = container.file, .index = @fromBackingInt(@intCast(i)) };
        if (std.meta.eql(decl, answer)) return record.name;
    }
    if (depth == 2) return null;
    for (model.declarations, 0..) |record, i| {
        if (record.scope != container.scope or !record.public or record.kind != .variable) continue;
        const value = try c.facts.declaration(.{ .file = container.file, .index = @fromBackingInt(@intCast(i)) });
        const inner = switch (value) {
            .container => |held| held,
            // A namespace a build chooses is no one path every build spells.
            .alternatives => continue,
            else => continue,
        };
        if (inner.file == container.file and inner.scope == container.scope) continue;
        const rest = (try pathTo(c, inner, answer, depth + 1)) orelse continue;
        return try c.allocator.print("{s}.{s}", .{ record.name, rest });
    }
    return null;
}

/// The container alias of the target whose value a site is. Only a private one, so every use
/// of it is in this file.
const Alias = struct { decl: Model.Declaration.Id, init: Ast.Node.Index };

fn aliasOf(c: *Context, site: Governed.Site, sites: []const Governed.Site) ?Alias {
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    const decl: Model.Declaration.Id = found: {
        const parent = model.parentOf(site.node) orelse return null;
        for (model.declarations, 0..) |record, i| if (record.node == parent and record.kind == .variable) break :found @fromBackingInt(@intCast(i));
        return null;
    };
    const record = model.declarations[@backingInt(decl)];
    if (record.kind != .variable or record.public or record.exported) return null;
    const variable = tree.fullVarDecl(record.node) orelse return null;
    if (tree.tokenTag(variable.ast.mut_token) != .keyword_const) return null;
    if (c.facts.functionHolding(c.file, record.node) != null) return null;
    const init = variable.ast.init_node.unwrap() orelse return null;
    for (sites) |each| if (each.node == init and !each.through_alias and each.index == site.index) return .{ .decl = decl, .init = init };
    return null;
}

/// The call whose callee is `node`.
fn callOf(tree: *const Ast, model: *const Model, node: Ast.Node.Index) ?Ast.Node.Index {
    const parent = model.parentOf(node) orelse return null;
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, parent) orelse return null;
    return if (call.ast.fn_expr == node) parent else null;
}

/// The edit writing `text` in place of `node`.
fn replacing(tree: *const Ast, node: Ast.Node.Index, text: []const u8) Report.Edit {
    return .{ .start = tree.tokenStart(tree.firstToken(node)), .end = tree.tokenToSpan(tree.lastToken(node)).end, .text = text };
}

/// The edit adding a call's arguments as written, as a string, as its last argument: after
/// the last argument, or on a line of its own where the arguments end with a comma.
fn messageArgument(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!?Report.Edit {
    var buffer: [1]Ast.Node.Index = undefined;
    const arguments = (tree.fullCall(&buffer, node) orelse return null).ast.params;
    if (arguments.len == 0) return null;
    const first = tree.tokenStart(tree.firstToken(arguments[0]));
    const last_token = tree.lastToken(arguments[arguments.len - 1]);
    const written = tree.source[first..tree.tokenToSpan(last_token).end];
    var text: std.ArrayList(u8) = .empty;
    var spaced = false;
    for (written) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            spaced = true;
            continue;
        }
        if (spaced and text.items.len != 0) try text.append(c.allocator, ' ');
        spaced = false;
        switch (byte) {
            '\\', '"' => try text.appendSlice(c.allocator, &.{ '\\', byte }),
            0...0x1f, 0x7f => try text.print(c.allocator, "\\x{x:0>2}", .{byte}),
            else => try text.append(c.allocator, byte),
        }
    }
    if (tree.tokenTag(last_token + 1) == .comma) {
        const comma_end = tree.tokenToSpan(last_token + 1).end;
        const line_start = if (std.mem.findScalarLast(u8, tree.source[0..first], '\n')) |newline| newline + 1 else 0;
        var indent_end = line_start;
        while (indent_end < first and (tree.source[indent_end] == ' ' or tree.source[indent_end] == '\t')) indent_end += 1;
        return .{ .start = comma_end, .end = comma_end, .text = try c.allocator.print("\n{s}\"{s}\",", .{ tree.source[line_start..indent_end], text.items }) };
    }
    const end = tree.tokenToSpan(last_token).end;
    return .{ .start = end, .end = end, .text = try c.allocator.print(", \"{s}\"", .{text.items}) };
}

fn declName(project: *const Project, decl: Facts.Decl) []const u8 {
    return project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
}

/// P005, glint's own replaced declaration: a reference outside test code that resolves to std's
/// `debug.print`, a hygiene rule, so one that does not resolve is silent. The program's output
/// or logging is the answer; a project names the file that is its output in a seam.
pub fn debugPrints(c: *Context) Context.Error!void {
    if (!c.config.has(.P005)) return;
    const found = try Governed.resolve(c, .P005, &.{.{ .source = "std", .declaration = "debug.print", .production = true }}, &.{0});
    var sites: std.ArrayList(Governed.Site) = .empty;
    var unread: std.ArrayList(Governed.Unread) = .empty;
    try Governed.sitesLeaving(c, found, &sites, &unread);
    for (sites.items) |site| try c.atDefinition(.P005, site.token, "production debug print; use the program's output or logging", site.decl);
}

/// Each declaration a package names in place of std's `debug.assert`: every `.with` of an entry,
/// under any rule, whose target is it. Assertion metrics count calls of them (Metrics.zig).
pub fn assertions(c: *Context) Context.Error![]const Facts.Decl {
    _ = try entries(c, "");
    const all = try c.facts.memo(Entries);
    var found: std.ArrayList(Facts.Decl) = .empty;
    for (all.all.items) |entry| {
        const replaced = for (entry.replacement.declarations()) |decl| {
            if (try Governed.isStd(c, decl, "debug.assert") == .yes) break true;
        } else false;
        if (!replaced) continue;
        for (entry.replacement.with) |answer| if (answer.declaration()) |decl| try found.append(c.allocator, decl);
    }
    return found.items;
}
