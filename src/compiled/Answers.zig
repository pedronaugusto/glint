//! Facts' answers from the compilation (`Compiled.zig`): what the compiler gave a function's
//! locals and parameters, in each instance of it it compiled. The AST binds the name (Model);
//! the compilation types it. A local of a function no compiled root holds is not reached.
const std = @import("std");
const Ast = std.zig.Ast;
const Facts = @import("../Facts.zig");
const Model = @import("../Model.zig");
const Project = @import("../Project.zig");
const Compiled = @import("Compiled.zig");

/// The value of the local or parameter `decl` as the compiled instances of its function give
/// it: a value of each type they give it, `alternatives` where they differ. Unknown
/// (`not_reached`) where compiled roots are given and none holds its function. Null where one
/// holds it without the name (a value fixed at compile time, which the compiler does not
/// emit), or gives it a type not yet read from the compilation.
pub fn local(facts: *Facts, decl: Facts.Decl) Facts.ResolveError!?Facts.Value {
    if (facts.compiled.len == 0) return null;
    const source = facts.project.at(decl.file);
    const model = &source.model;
    const tree = &source.file.tree;
    const record = model.declarations[@backingInt(decl.index)];
    const owner = functionNode(model, tree, record.scope) orelse return null;
    const line = lineOf(tree, tree.firstToken(owner));
    var values: std.ArrayList(Facts.Value) = .empty;
    var held = false;
    for (facts.compiled) |c| {
        const file = (try c.fileId(source.input.name)) orelse continue;
        const place: Compiled.Place = .{ .file = file, .line = line };
        if (!c.holds(place)) continue;
        held = true;
        const types = try c.localTypes(facts.gpa, place, record.name);
        for (types) |t| {
            const type_value = (try typeValue(facts, c, t, 0)) orelse return null;
            const value = try facts.instance(type_value);
            for (values.items) |seen| {
                if (Facts.sameValue(seen, value)) break;
            } else try values.append(facts.gpa, value);
        }
    }
    if (!held) return .{ .unknown = .not_reached };
    return switch (values.items.len) {
        0 => null,
        1 => values.items[0],
        else => .{ .alternatives = values.items },
    };
}

/// The function or test whose body holds `scope`, by its declaration's node.
fn functionNode(model: *const Model, tree: *const Ast, scope: Model.Scope.Id) ?Ast.Node.Index {
    var at: ?Model.Scope.Id = scope;
    while (at) |id| {
        const s = model.scopes[@backingInt(id)];
        switch (s.kind) {
            .function, .@"test" => {
                var node = s.node;
                while (true) {
                    switch (tree.nodeTag(node)) {
                        .fn_decl, .test_decl => return node,
                        else => node = model.parentOf(node) orelse return null,
                    }
                }
            },
            .container, .file => return null,
            else => at = s.parent,
        }
    }
    return null;
}

fn lineOf(tree: *const Ast, token: Ast.TokenIndex) u32 {
    return @intCast(tree.tokenLocation(0, token).line + 1); // safe: a file's lines fit u32, as Ast counts its tokens in u32
}

/// What the compilation's type `ty` is, as Facts holds a type: a container the program
/// declares, a pointer to one, a primitive. Null for a type not read from it yet.
fn typeValue(facts: *Facts, c: *const Compiled, ty: u32, depth: u8) Facts.ResolveError!?Facts.Value {
    if (depth > 16) return null;
    const e = c.dwarf.entries.slice();
    const name = e.items(.name)[ty];
    switch (e.items(.kind)[ty]) {
        .typedef, .@"const", .@"volatile" => return typeValue(facts, c, c.entry(e.items(.type)[ty]) orelse return null, depth + 1),
        .base => return if (Model.primitive(name)) .{ .primitive = name } else null,
        .pointer => {
            const size: std.builtin.Type.Pointer.Size = if (std.mem.startsWith(u8, name, "[*c]")) .c else if (std.mem.startsWith(u8, name, "[*")) .many else if (std.mem.startsWith(u8, name, "*")) .one else return null;
            const child = (try typeValue(facts, c, c.entry(e.items(.type)[ty]) orelse return null, depth + 1)) orelse return null;
            return try facts.pointerTo(child, size);
        },
        .structure, .@"union", .enumeration => {
            if (std.mem.startsWith(u8, name, "[]")) {
                // A slice: a pointer to its elements, as Facts holds one.
                const ptr = c.member(ty, "ptr") orelse return null;
                const many = c.entry(e.items(.type)[c.strip(ptr, false)]) orelse return null;
                const child = (try typeValue(facts, c, many, depth + 1)) orelse return null;
                return try facts.pointerTo(child, .slice);
            }
            // Optionals, error unions and tuples are not read from the compilation yet.
            if (std.mem.startsWith(u8, name, "?") or std.mem.findScalar(u8, name, '!') != null or std.mem.startsWith(u8, name, "struct {")) return null;
            const container = (try containerOf(facts, c, ty)) orelse return null;
            return .{ .container = container };
        },
        else => return null,
    }
}

/// The program's container the compilation's type `ty` is: the one declared on its line, or a
/// file's own. Null for an instance of a type function, whose arguments that container lacks.
fn containerOf(facts: *Facts, c: *const Compiled, ty: u32) Facts.ResolveError!?Facts.Container {
    const file = c.fileOf(ty);
    if (file == Compiled.none) return null;
    const project_file = projectFile(facts, c.paths.keys()[file]) orelse return null;
    const source = facts.project.at(project_file);
    const model = &source.model;
    const tree = &source.file.tree;
    // A type function's instance: its container is the one the function returns, at the line
    // every instance shares, but a value of it read as that container alone would lose the
    // arguments it was made with (aegis's `Checked(u32)`, read as the bare `Checked` structure,
    // hid its narrowing casts from A004). Its members' types are the compilation's to answer
    // (`Compiled.member`), not yet asked here, so the source's reading stands.
    if (c.instance(ty)) return null;
    if (c.placeOf(ty)) |place| {
        if (c.files[c.origin(ty)] == Compiled.none or c.dwarf.entries.items(.line)[c.origin(ty)] != 0) {
            for (model.scopes, 0..) |s, i| {
                if (s.kind != .container) continue;
                if (lineOf(tree, s.first) == place.line) return .{ .file = project_file, .scope = @fromBackingInt(@intCast(i)) }; // safe: scopes are counted in u32
            }
        }
    }
    // A file's own structure.
    if (c.file_structs.get(file)) |s| if (s == ty) return .{ .file = project_file, .scope = model.root() };
    return null;
}

/// The project's file a compiled path names, as its input is named.
fn projectFile(facts: *Facts, path: []const u8) ?Project.FileId {
    for (0..facts.project.count()) |i| {
        const id = facts.project.fileAt(i) catch continue;
        if (std.mem.eql(u8, facts.project.at(id).input.name, path)) return id;
    }
    return null;
}
