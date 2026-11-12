//! The rules a package declares to read `.governed` and `.exits` (PackageRules, vocabulary version
//! 2), outside the declaring package and outside a seam the project declares.
//!
//! A rule that reads `.governed` is a ban on a governed type's own state: a touch of an internal
//! field (a read, a write, a struct literal naming it, `@field` and the other field builtins), a
//! cast that makes the type from another or reinterprets it (`@enumFromInt`, `@intFromEnum`,
//! `@backingInt`, `@fromBackingInt`, `@bitCast`, `@ptrCast` and the pointer casts), reflection
//! over it (`@typeInfo`, `@field`, `@hasField`, `@FieldType`, the offsets), and a library's
//! reflective function given it (`std.mem.zeroes`, `asBytes`, `bytesToValue`, `std.meta.fields`).
//! `@sizeOf` and `@alignOf` read no state. A reference spelling an internal field's name that
//! does not resolve cannot be shown to be another field: a finding. A cast or reflection whose
//! operand does not resolve spells no governed name and is silent.
//!
//! A rule that reads `.exits` is hygiene: an exit's result (`raw()`) given straight to arithmetic, a
//! comparison or a narrowing cast loses the type's checks. Only a call that resolves to an exit
//! is read, and only that certain shape: a value kept in a name first is not followed.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const PackageRules = @import("PackageRules.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Rule = @import("Rule.zig");

/// One `.governed` entry as the run reads it, with the package that declares it.
pub const Entry = struct { governance: PackageRules.Governance, package: PackageRules.Identity };

/// Every `.governed` entry of the run's packages, each once, for the run.
const Entries = struct { built: bool = false, all: std.ArrayList(Entry) = .empty };

/// The entries the package named `package` declares.
pub fn entries(c: *Context, package: []const u8) Context.Error![]const Entry {
    const rule_memory = c.keep();
    defer c.allocator = rule_memory;
    const found = try c.facts.memo(Entries);
    if (!found.built) {
        found.built = true;
        for (c.project.sources) |*source| {
            if (source.input.kind == .zon) continue;
            if (c.facts.member(c.facts.rootOf(source.id), "lint_rules") == null) continue;
            const rules = try PackageRules.of(c.facts, source.id);
            for (rules.governance) |governance| {
                const same = for (found.all.items) |known| {
                    if (known.governance.file == governance.file and known.governance.node == governance.node) break true;
                } else false;
                if (!same) try found.all.append(c.facts.gpa, .{ .governance = governance, .package = rules.package });
            }
        }
    }
    var named: std.ArrayList(Entry) = .empty;
    for (found.all.items) |entry| if (std.mem.eql(u8, entry.package.name, package)) try named.append(c.allocator, entry);
    return named.items;
}

/// A rule that reads `.governed`.
pub fn check(c: *Context, definition: Rule.Definition) Context.Error!void {
    const declared = definition.declared orelse return;
    const all = try entries(c, declared.package);
    if (all.len == 0) return;
    // The declaring package's own files are its types' internals.
    if (all[0].package.eql(PackageRules.Identity.of(c.project, c.file))) return;
    const tree = &c.project.at(c.file).file.tree;
    var reported: std.AutoHashMapUnmanaged(Ast.TokenIndex, void) = .empty;

    // Internal fields: each field's declaration, read where a reference reaches it.
    var fields: std.ArrayList(Governed.Governed) = .empty;
    var types: std.ArrayList(Facts.Container) = .empty;
    for (all, 0..) |entry, i| {
        try types.appendSlice(c.allocator, entry.governance.containers);
        for (entry.governance.internal) |decl| try fields.append(c.allocator, .{
            .target = .{ .declaration = declName(c.project, decl), .production = true },
            .index = i,
            .name = declName(c.project, decl),
            .decls = try c.allocator.dupe(Facts.Decl, &.{decl}),
            .symbol = null,
        });
    }
    var sites: std.ArrayList(Governed.Site) = .empty;
    var unread: std.ArrayList(Governed.Unread) = .empty;
    try Governed.sitesLeaving(c, fields.items, &sites, &unread);
    for (sites.items) |site| {
        if ((try reported.getOrPut(c.allocator, site.token)).found_existing) continue;
        const entry = all[site.index];
        try c.atDefinition(definition.id, site.token, try c.allocator.print("internal field '{s}' of {s}: {s}'s alone; use the type's own API", .{ declName(c.project, site.decl), typeName(c, entry), entry.package.name }), site.decl);
    }
    for (unread.items) |missed| {
        const token = tree.firstToken(missed.node);
        if ((try reported.getOrPut(c.allocator, token)).found_existing) continue;
        try c.at(definition.id, token, try c.allocator.print("a reference spelling an internal field {s} governs does not resolve ({t}), so it cannot be shown to be another", .{ definition.name, missed.why }));
    }

    // Casts and reflection over a governed type.
    for (tree.nodes.items(.tag), 0..) |_, raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const name = Facts.builtinName(tree, node) orelse continue;
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        const kind: enum { cast, reflection } = if (among(&casts, name)) .cast else if (among(&reflection, name)) .reflection else continue;
        const found = (try governedIn(c, node, name, kind == .cast, types.items)) orelse continue;
        if ((try reported.getOrPut(c.allocator, token)).found_existing) continue;
        const entry = ofContainer(all, found) orelse all[0];
        try c.at(definition.id, token, try c.allocator.print("{s} over {s}: its state is {s}'s alone; use the type's own makers and API", .{ name, typeName(c, entry), entry.package.name }));
    }

    // A library's reflective functions over a governed type: one that makes it from what the
    // caller hands it (`std.mem.zeroes(T)`, `std.mem.bytesToValue(T, b)`), or reads whatever
    // it is handed (`std.mem.asBytes(&t)`, `std.meta.fields(T)`).
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        const callee = switch (try Governed.madeByCall(c, node, types.items)) {
            .yes => |callee| callee,
            .no, .unknown => try Governed.reflectedByCall(c, node, types.items),
        } orelse continue;
        const at = tree.firstToken(node);
        if ((try reported.getOrPut(c.allocator, at)).found_existing) continue;
        const named = c.project.at(callee.file).model.declarations[@backingInt(callee.index)].name;
        try c.at(definition.id, at, try c.allocator.print("{s} reads or makes a governed type by reflection: its state is {s}'s alone; use the type's own makers and API", .{ named, all[0].package.name }));
    }
}

/// The builtins that make a value of one type from another's bits, or reinterpret a pointer.
const casts = [_][]const u8{ "@enumFromInt", "@intFromEnum", "@backingInt", "@fromBackingInt", "@bitCast", "@addrSpaceCast", "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@ptrFromInt", "@errorFromInt", "@intFromError" };
/// The builtins that read a type's fields or layout by name.
const reflection = [_][]const u8{ "@typeInfo", "@field", "@hasField", "@FieldType", "@offsetOf", "@bitOffsetOf", "@fieldParentPtr" };

fn among(names: []const []const u8, name: []const u8) bool {
    for (names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

/// The governed type a cast's operand or result is, or a reflective builtin reads, if any.
fn governedIn(c: *Context, node: Ast.Node.Index, name: []const u8, cast: bool, types: []const Facts.Container) Context.Error!?Facts.Container {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len == 0) return null;
    // `@fieldParentPtr`'s holder is the type its result points at; every other one reads its
    // first operand (`@field(h, n)`, `@typeInfo(T)`, `@offsetOf(T, n)`), a cast its last.
    const operand = if (std.mem.eql(u8, name, "@fieldParentPtr")) null else if (cast) args[args.len - 1] else args[0];
    if (operand) |each| if (madeType(try c.facts.resolve(c.file, each), types)) |found| return found;
    if (!cast and operand != null) return null;
    return madeType(try c.facts.castTypeIn(null, c.file, node), types);
}

/// The one of `types` a value is, holds by pointer, optional or error union, or names as a type.
fn madeType(value: Facts.Value, types: []const Facts.Container) ?Facts.Container {
    var at = value;
    while (true) at = switch (at) {
        .pointer => |inner| inner.child.*,
        .optional, .error_union => |inner| inner.*,
        .alternatives => |each| {
            for (each) |one| if (madeType(one, types)) |found| return found;
            return null;
        },
        else => break,
    };
    const found = switch (at) {
        .instance, .container => |found| found,
        else => return null,
    };
    for (types) |t| if (t.file == found.file and t.scope == found.scope) return t;
    return null;
}

/// A rule that reads `.exits`: an exit's result given straight to arithmetic, a comparison or a
/// narrowing cast.
pub fn exits(c: *Context, definition: Rule.Definition) Context.Error!void {
    const declared = definition.declared orelse return;
    const all = try entries(c, declared.package);
    if (all.len == 0) return;
    if (all[0].package.eql(PackageRules.Identity.of(c.project, c.file))) return;
    var any = false;
    for (all) |entry| any = any or entry.governance.exits.len != 0;
    if (!any) return;
    const tree = &c.project.at(c.file).file.tree;
    const model = &c.project.at(c.file).model;
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        const call = (try Facts.calls.at(c.facts, c.file, node)) orelse continue;
        const callee = switch (call.callee) {
            .function => |function| function,
            .choice, .any => continue,
        };
        const entry = ofExit(all, callee) orelse continue;
        // The place the result is given to, past parentheses.
        var child = node;
        var parent = model.parentOf(node) orelse continue;
        while (tree.nodeTag(parent) == .grouped_expression) {
            child = parent;
            parent = model.parentOf(parent) orelse break;
        }
        const shape: []const u8 = switch (tree.nodeTag(parent)) {
            .add, .sub, .mul, .div, .mod, .shl, .shr, .add_wrap, .sub_wrap, .mul_wrap, .add_sat, .sub_sat, .mul_sat, .shl_sat, .bit_and, .bit_or, .bit_xor, .negation, .negation_wrap, .bit_not => "arithmetic",
            .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_shl, .assign_shr, .assign_add_wrap, .assign_sub_wrap, .assign_mul_wrap, .assign_add_sat, .assign_sub_sat, .assign_mul_sat, .assign_shl_sat, .assign_bit_and, .assign_bit_or, .assign_bit_xor => "arithmetic",
            .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => "a comparison",
            else => blk: {
                const builtin = Facts.builtinName(tree, parent) orelse continue;
                if (!std.mem.eql(u8, builtin, "@intCast") and !std.mem.eql(u8, builtin, "@truncate")) continue;
                break :blk "a narrowing cast";
            },
        };
        try c.at(definition.id, token, try c.allocator.print("{s}'s bare value given to {s} loses its checks: use the type's own operation", .{ typeName(c, entry), shape }));
    }
}

/// The entry that governs `container`.
fn ofContainer(all: []const Entry, container: Facts.Container) ?Entry {
    for (all) |each| for (each.governance.containers) |one| if (one.file == container.file and one.scope == container.scope) return each;
    return null;
}

/// The entry `exit` is an exit of.
fn ofExit(all: []const Entry, exit: Facts.Decl) ?Entry {
    for (all) |each| for (each.governance.exits) |one| if (std.meta.eql(one, exit)) return each;
    return null;
}

fn declName(project: *const Project, decl: Facts.Decl) []const u8 {
    return project.at(decl.file).model.declarations[@backingInt(decl.index)].name;
}

/// The governed type as its entry writes it.
fn typeName(c: *Context, entry: Entry) []const u8 {
    const decl = entry.governance.type.declaration() orelse return "a governed type";
    return declName(c.project, decl);
}
