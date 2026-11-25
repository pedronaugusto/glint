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
//! comparison or a narrowing cast (into a type that cannot hold every value of the exit's, both
//! widths known) loses the type's checks. Only a call that resolves to an exit
//! is read, and only that certain shape: straight, or through a const local it initializes and the
//! const locals that alias it; a var or a call's argument takes the value out of the reading.
const std = @import("std");
const Ast = std.zig.Ast;
const Context = @import("RuleContext.zig");
const Governed = @import("Governed.zig");
const PackageRules = @import("PackageRules.zig");
const Facts = @import("Facts.zig");
const Model = @import("Model.zig");
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
    const found = try c.memo(Entries);
    if (!found.built) {
        found.built = true;
        for (c.project.sources) |*source| {
            if (source.input.kind == .zon) continue;
            if (c.member(c.rootOf(source.id), "lint_rules") == null) continue;
            const rules = try c.packageRules(source.id);
            for (rules.governance) |governance| {
                const same = for (found.all.items) |known| {
                    if (known.governance.file == governance.file and known.governance.node == governance.node) break true;
                } else false;
                if (!same) try found.all.append(c.runAllocator(), .{ .governance = governance, .package = rules.package });
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
    // Under a ban, a reference spelling an internal field that does not resolve is no pass
    // (`Context.unknownAt`). A hygiene rule reports only what it resolves.
    const ban = declared.kind == .ban;
    if (ban) for (unread.items) |missed| {
        const token = tree.firstToken(missed.node);
        if ((try reported.getOrPut(c.allocator, token)).found_existing) continue;
        try c.unknownAt(definition.id, token, missed.why);
    };

    // Casts and reflection over a governed type.
    for (tree.nodes.items(.tag), 0..) |_, raw| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const name = Facts.builtinName(tree, node) orelse continue;
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        const kind: enum { cast, reflection } = if (among(&casts, name)) .cast else if (among(&reflection, name)) .reflection else continue;
        // A cast written inside another (`@ptrCast(@alignCast(p))`) is one conversion: the
        // outermost reads it, from the innermost operand to the outermost's place.
        if (kind == .cast and enclosingCast(c, tree, node) != null) continue;
        // `@field` with a name it spells (`@field(S, "expose")`, a `const` holding one) is a
        // member reference, read as one above (an internal field's is that finding); only a name
        // it computes is reflection.
        if (std.mem.eql(u8, name, "@field") and try writtenName(c, tree, node)) continue;
        const found = switch (try governedIn(c, node, name, kind == .cast, types.items)) {
            .found => |found| found,
            .none => continue,
            .unknown => |why| {
                if (ban and !(try reported.getOrPut(c.allocator, token)).found_existing) try c.unknownAt(definition.id, token, why);
                continue;
            },
        };
        if ((try reported.getOrPut(c.allocator, token)).found_existing) continue;
        const entry = ofContainer(all, found) orelse all[0];
        try c.at(definition.id, token, try c.allocator.print("{s} over {s}: its state is {s}'s alone; use the type's own makers and API", .{ name, typeName(c, entry), entry.package.name }));
    }
    // A governed type or value named to one of std's readers or makers of a value (fmt, json, zon,
    // hash, testing, mem, meta: `Governed.namedStd`, one table each).
    // of its own `comptime T: type`): fmt, json, hash, mem, testing (`Governed.handedToStd`).
    for (tree.nodes.items(.tag), 0..) |tag, raw| {
        switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const token = tree.nodeMainToken(node);
        if (c.inTest(token)) continue;
        const at = tree.firstToken(node);
        const callee = switch (try Governed.namedStd(c, node, types.items)) {
            .yes => |callee| callee,
            .no => continue,
            .unknown => |why| {
                if (ban and !(try reported.getOrPut(c.allocator, at)).found_existing) try c.unknownAt(definition.id, at, why);
                continue;
            },
        };
        if ((try reported.getOrPut(c.allocator, at)).found_existing) continue;
        const named = c.project.at(callee.file).model.declarations[@backingInt(callee.index)].name;
        try c.at(definition.id, at, try c.allocator.print("{s} reads or makes a governed value by its type: its state is {s}'s alone; hand it the type's exposed value or use its exits", .{ named, all[0].package.name }));
    }
}

/// The builtins that make a value of one type from another's bits, or reinterpret a pointer.
const casts = [_][]const u8{ "@enumFromInt", "@intFromEnum", "@backingInt", "@fromBackingInt", "@bitCast", "@addrSpaceCast", "@ptrCast", "@alignCast", "@constCast", "@volatileCast", "@ptrFromInt", "@errorFromInt", "@intFromError" };
/// The builtins that read a type's fields or layout by name.
const reflection = [_][]const u8{ "@typeInfo", "@field", "@hasField", "@FieldType", "@offsetOf", "@bitOffsetOf", "@fieldParentPtr" };

/// Whether a `@field`'s name is one it spells (`Facts.fieldName`'s `.name`).
fn writtenName(c: *Context, tree: *const Ast, node: Ast.Node.Index) Context.Error!bool {
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len != 2) return false;
    return switch (try c.fieldName(c.file, args[1])) {
        .name => true,
        .each_of, .names, .computed => false,
    };
}

fn among(names: []const []const u8, name: []const u8) bool {
    for (names) |each| if (std.mem.eql(u8, each, name)) return true;
    return false;
}

/// The governed type a cast's operand or result is, or a reflective builtin reads: found, none,
/// or unknown where what it reads is unknown and none it reads is governed.
const In = union(enum) { found: Facts.Container, none, unknown: Facts.Unknown };
fn governedIn(c: *Context, node: Ast.Node.Index, name: []const u8, cast: bool, types: []const Facts.Container) Context.Error!In {
    const tree = &c.project.at(c.file).file.tree;
    var buffer: [2]Ast.Node.Index = undefined;
    const args = Facts.builtinArgs(tree, node, &buffer);
    if (args.len == 0) return .none;
    // `@fieldParentPtr`'s holder is the type its result points at; every other one reads its
    // first operand (`@field(h, n)`, `@typeInfo(T)`, `@offsetOf(T, n)`), a cast its last.
    const operand = if (std.mem.eql(u8, name, "@fieldParentPtr")) null else if (cast) innermost(tree, args[args.len - 1]) else args[0];
    var unknown: ?Facts.Unknown = null;
    if (operand) |each| {
        const value = try c.resolveIn(c.file, each);
        if (madeType(value, types)) |found| return .{ .found = found };
        unknown = Governed.unknownIn(value);
    }
    if (!cast and operand != null) return if (unknown) |why| .{ .unknown = why } else .none;
    // A cast to an integer makes a number, never one of `types`: its operand alone is read.
    if (among(&to_integer, name)) return if (unknown) |why| .{ .unknown = why } else .none;
    const result = try c.castType(c.file, outermost(c, tree, node));
    if (madeType(result, types)) |found| return .{ .found = found };
    if (unknown orelse Governed.unknownIn(result)) |why| return .{ .unknown = why };
    return .none;
}

/// The cast `node` is written inside, past parentheses, if one.
fn enclosingCast(c: *Context, tree: *const Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    const model = &c.project.at(c.file).model;
    var parent = model.parentOf(node) orelse return null;
    while (tree.nodeTag(parent) == .grouped_expression) parent = model.parentOf(parent) orelse return null;
    return if (among(&casts, Facts.builtinName(tree, parent) orelse return null)) parent else null;
}

/// The casts whose result is an integer by what they are, whatever their place.
const to_integer = [_][]const u8{ "@intFromEnum", "@backingInt", "@intFromError", "@intFromPtr" };

/// The casts that keep what a pointer points at: an inner one's result is its outer one's.
const keeping = [_][]const u8{ "@alignCast", "@constCast", "@volatileCast", "@addrSpaceCast" };

/// The outermost of the pointee-keeping casts `node` is written inside (itself where none):
/// the place that types it (`@alignCast(@fieldParentPtr("f", p))` placed in `*T` makes a `*T`).
fn outermost(c: *Context, tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (enclosingCast(c, tree, at)) |outer| {
        if (!among(&keeping, Facts.builtinName(tree, outer).?)) break; // safe: enclosingCast gives a builtin call
        at = outer;
    }
    return at;
}

/// The operand under every cast written inside one another (`@ptrCast(@alignCast(p))`'s `p`),
/// past parentheses.
fn innermost(tree: *const Ast, node: Ast.Node.Index) Ast.Node.Index {
    var at = node;
    while (true) {
        while (tree.nodeTag(at) == .grouped_expression) at = tree.nodeData(at).node_and_token[0];
        const name = Facts.builtinName(tree, at) orelse return at;
        if (!among(&casts, name)) return at;
        var buffer: [2]Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, at, &buffer);
        if (args.len == 0) return at;
        at = args[args.len - 1];
    }
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

/// A rule that reads `.exits`: an exit's result given to arithmetic, a comparison or a narrowing
/// cast, straight or through a const local it initializes (and the const locals that alias it), at
/// each use of the local that is one. A var takes the value out of this reading, as a call's
/// argument does: what it is given to is no longer this function's expression.
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
        const call = (try c.callAt(c.file, node)) orelse continue;
        const callee = switch (call.callee) {
            .function => |function| function,
            .choice, .any => continue,
        };
        const entry = ofExit(all, callee) orelse continue;
        if (try bareUse(c, tree, model, node)) |shape| {
            try reportBare(c, definition, entry, token, shape);
            continue;
        }
        // The const local the result initializes, then each const local that aliases one.
        var held: [16]Model.Declaration.Id = undefined;
        var count: usize = 0;
        if (constLocal(tree, model, node)) |local| {
            held[0] = local;
            count = 1;
        }
        var next: usize = 0;
        while (next < count) : (next += 1) {
            for (model.references) |reference| {
                const declaration = reference.declaration orelse continue;
                if (declaration != held[next]) continue;
                if (try bareUse(c, tree, model, reference.node)) |shape| {
                    try reportBare(c, definition, entry, reference.token, shape);
                } else if (constLocal(tree, model, reference.node)) |alias| {
                    if (count < held.len and std.mem.findScalar(Model.Declaration.Id, held[0..count], alias) == null) {
                        held[count] = alias;
                        count += 1;
                    }
                }
            }
        }
    }
}

fn reportBare(c: *Context, definition: Rule.Definition, entry: Entry, token: Ast.TokenIndex, shape: []const u8) Context.Error!void {
    try c.at(definition.id, token, try c.allocator.print("{s}'s bare value given to {s} loses its checks: use the type's own operation", .{ typeName(c, entry), shape }));
}

/// What `value`, an exit's bare result, is given to past parentheses, where that loses its checks:
/// checked arithmetic, a comparison or a narrowing cast; null for anything else.
fn bareUse(c: *Context, tree: *const Ast, model: *const Model, value: Ast.Node.Index) Context.Error!?[]const u8 {
    var parent = model.parentOf(value) orelse return null;
    while (tree.nodeTag(parent) == .grouped_expression) parent = model.parentOf(parent) orelse return null;
    return switch (tree.nodeTag(parent)) {
        // The arithmetic Zig checks. Bits, shifts and wrapping or saturating arithmetic check
        // nothing to lose, and a type has no operation of its own for them (a parity bit, a
        // wheel's slot of a raw instant).
        .add, .sub, .mul, .div, .mod, .negation, .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod => "arithmetic",
        .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal => "a comparison",
        else => {
            const builtin = Facts.builtinName(tree, parent) orelse return null;
            if (!std.mem.eql(u8, builtin, "@intCast") and !std.mem.eql(u8, builtin, "@truncate")) return null;
            // Only a cast into a type that cannot hold every value of the exit's: a widening
            // loses nothing, and a width either side's build decides is not read (hygiene).
            const from = intType(try c.resolveIn(c.file, value)) orelse return null;
            const into = intType(try c.castType(c.file, parent)) orelse return null;
            if (holdsAll(into, from)) return null;
            return "a narrowing cast";
        },
    };
}

/// The const local of a function `value` initializes, past parentheses (`const x = value;`); null
/// for a var, a container's declaration, a destructure or any other place.
fn constLocal(tree: *const Ast, model: *const Model, value: Ast.Node.Index) ?Model.Declaration.Id {
    var child = value;
    var parent = model.parentOf(value) orelse return null;
    while (tree.nodeTag(parent) == .grouped_expression) {
        child = parent;
        parent = model.parentOf(parent) orelse return null;
    }
    const declaration = tree.fullVarDecl(parent) orelse return null;
    if (tree.tokenTag(declaration.ast.mut_token) != .keyword_const) return null;
    if (declaration.ast.init_node.unwrap() != child) return null;
    for (model.declarations, 0..) |each, index| {
        if (each.kind != .variable or each.node != parent) continue;
        return switch (model.scopes[@backingInt(each.scope)].kind) {
            .file, .container => null,
            else => @fromBackingInt(@intCast(index)),
        };
    }
    return null;
}

/// An integer type of a width every build gives it (`u32`, `i7`), as a value's type names it.
const Int = struct { signed: bool, bits: u16 };

fn intType(value: Facts.Value) ?Int {
    const name = switch (value) {
        .primitive => |name| name,
        // A width a build chooses is not read: hygiene is silent where it does not know.
        .alternatives => return null,
        else => return null,
    };
    if (name.len < 2 or (name[0] != 'u' and name[0] != 'i')) return null;
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    return .{ .signed = name[0] == 'i', .bits = bits };
}

/// Whether every value of `from` is one of `into`.
fn holdsAll(into: Int, from: Int) bool {
    if (from.signed and !into.signed) return false;
    if (!from.signed and into.signed) return into.bits > from.bits;
    return into.bits >= from.bits;
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
