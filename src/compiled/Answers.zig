//! What the compilation (`Compiled.zig`) answers, in glint's own terms: the types the compiler
//! gave a function's locals and parameters, in each instance of it it compiled. The AST binds
//! the name (Model); the compilation types it. A local of a function no compiled root holds is
//! not reached. Facts reads these answers as its values; nothing here names Facts.
const std = @import("std");
const Ast = std.zig.Ast;
const Model = @import("../Model.zig");
const Project = @import("../Project.zig");
const Compiled = @import("Compiled.zig");

/// A type as the compilation gives it: a primitive, a pointer to one of these, or a container
/// the program declares (a file's own structure, or one declared on its line).
pub const Type = union(enum) {
    primitive: []const u8,
    pointer: struct { size: std.builtin.Type.Pointer.Size, child: *const Type },
    container: struct { file: Project.FileId, scope: Model.Scope.Id },
};

/// What the compiled roots give a local or parameter: not reached (roots are given and none
/// holds its function), or the types its function's compiled instances give it, each once.
pub const Local = union(enum) {
    not_reached,
    types: []const Type,
};

/// What the compiled roots give the local or parameter `index` of `file`. Null where no root is
/// given; where one holds its function without the name (a value fixed at compile time, which
/// the compiler does not emit); or where it gives it a type not yet read from the compilation.
pub fn local(gpa: std.mem.Allocator, project: *const Project, compiled: []const *const Compiled, file: Project.FileId, index: Model.Declaration.Id) error{OutOfMemory}!?Local {
    if (compiled.len == 0) return null;
    const source = project.at(file);
    const model = &source.model;
    const tree = &source.file.tree;
    const record = model.declarations[@backingInt(index)];
    const owner = functionNode(model, tree, record.scope) orelse return null;
    const line = lineOf(tree, tree.firstToken(owner));
    var types: std.ArrayList(Type) = .empty;
    var held = false;
    for (compiled) |c| {
        const compiled_file = (try c.fileId(source.input.name)) orelse continue;
        const place: Compiled.Place = .{ .file = compiled_file, .line = line };
        if (!c.holds(place)) continue;
        held = true;
        for (try c.localTypes(gpa, place, record.name)) |t| {
            const answered = (try typeOf(gpa, project, c, t, 0)) orelse return null;
            for (types.items) |seen| {
                if (same(seen, answered)) break;
            } else try types.append(gpa, answered);
        }
    }
    if (!held) return .not_reached;
    if (types.items.len == 0) return null;
    return .{ .types = types.items };
}

fn same(a: Type, b: Type) bool {
    return switch (a) {
        .primitive => |name| b == .primitive and std.mem.eql(u8, name, b.primitive),
        .pointer => |pointer| b == .pointer and pointer.size == b.pointer.size and same(pointer.child.*, b.pointer.child.*),
        .container => |container| b == .container and container.file == b.container.file and container.scope == b.container.scope,
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

/// What the compilation's type `ty` is: a container the program declares, a pointer to one, a
/// primitive. Null for a type not read from it yet.
fn typeOf(gpa: std.mem.Allocator, project: *const Project, c: *const Compiled, ty: u32, depth: u8) error{OutOfMemory}!?Type {
    if (depth > 16) return null;
    const e = c.dwarf.entries.slice();
    const name = e.items(.name)[ty];
    switch (e.items(.kind)[ty]) {
        .typedef, .@"const", .@"volatile" => return typeOf(gpa, project, c, c.entry(e.items(.type)[ty]) orelse return null, depth + 1),
        .base => return if (Model.primitive(name)) .{ .primitive = name } else null,
        .pointer => {
            const size: std.builtin.Type.Pointer.Size = if (std.mem.startsWith(u8, name, "[*c]")) .c else if (std.mem.startsWith(u8, name, "[*")) .many else if (std.mem.startsWith(u8, name, "*")) .one else return null;
            const child = (try typeOf(gpa, project, c, c.entry(e.items(.type)[ty]) orelse return null, depth + 1)) orelse return null;
            return try pointerTo(gpa, child, size);
        },
        .structure, .@"union", .enumeration => {
            if (std.mem.startsWith(u8, name, "[]")) {
                // A slice: a pointer to its elements, as glint holds one.
                const ptr = c.member(ty, "ptr") orelse return null;
                const many = c.entry(e.items(.type)[c.strip(ptr, false)]) orelse return null;
                const child = (try typeOf(gpa, project, c, many, depth + 1)) orelse return null;
                return try pointerTo(gpa, child, .slice);
            }
            // Optionals, error unions and tuples are not read from the compilation yet.
            if (std.mem.startsWith(u8, name, "?") or std.mem.findScalar(u8, name, '!') != null or std.mem.startsWith(u8, name, "struct {")) return null;
            return containerOf(project, c, ty);
        },
        else => return null,
    }
}

fn pointerTo(gpa: std.mem.Allocator, child: Type, size: std.builtin.Type.Pointer.Size) error{OutOfMemory}!Type {
    const held = try gpa.create(Type);
    held.* = child;
    return .{ .pointer = .{ .size = size, .child = held } };
}

/// The program's container the compilation's type `ty` is: the one declared on its line, or a
/// file's own. Null for an instance of a type function: Zig names it with its arguments, at the
/// line its every instance shares, the line of the container the function returns, and a value
/// of it read as that container alone would lose the arguments it was made with. Its members'
/// types are the compilation's to answer (`Compiled.member`), not yet asked here, so the AST
/// answers it.
fn containerOf(project: *const Project, c: *const Compiled, ty: u32) ?Type {
    const file = c.fileOf(ty);
    if (file == Compiled.none) return null;
    if (c.instance(ty)) return null;
    const project_file = projectFile(project, c.paths.keys()[file]) orelse return null;
    const source = project.at(project_file);
    const model = &source.model;
    const tree = &source.file.tree;
    if (c.placeOf(ty)) |place| {
        if (c.files[c.origin(ty)] == Compiled.none or c.dwarf.entries.items(.line)[c.origin(ty)] != 0) {
            for (model.scopes, 0..) |s, i| {
                if (s.kind != .container) continue;
                if (lineOf(tree, s.first) == place.line) return .{ .container = .{ .file = project_file, .scope = @fromBackingInt(@intCast(i)) } }; // safe: scopes are counted in u32
            }
        }
    }
    // A file's own structure.
    if (c.file_structs.get(file)) |s| if (s == ty) return .{ .container = .{ .file = project_file, .scope = model.root() } };
    return null;
}

/// The project's file a compiled path names, as its input is named.
fn projectFile(project: *const Project, path: []const u8) ?Project.FileId {
    for (project.sources) |*source| if (std.mem.eql(u8, source.input.name, path)) return source.id;
    return null;
}
