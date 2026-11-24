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
    /// A type function's instance (`Checked(u32)`): the container its function returns, which
    /// alone would lose the arguments it was made with, and the compilation's own entry for it,
    /// whose members' and methods' types `member` and `result` answer with those arguments.
    instance: Instance,
};

pub const Instance = struct {
    file: Project.FileId,
    scope: Model.Scope.Id,
    compiled: *const Compiled,
    entry: u32,
};

/// The type the compilation gives `of`'s field `name`, read with its arguments; null where it
/// has no such field or its type is not read from the compilation yet.
pub fn member(gpa: std.mem.Allocator, project: *const Project, of: Instance, name: []const u8) error{OutOfMemory}!?Type {
    const t = of.compiled.member(of.entry, name) orelse return null;
    return typeOf(gpa, project, of.compiled, t, 0);
}

/// The type `of`'s function `name` returns, as the compilation gives it, read with its
/// arguments; null where it has no such function or its result's type is not read yet.
pub fn result(gpa: std.mem.Allocator, project: *const Project, of: Instance, name: []const u8) error{OutOfMemory}!?Type {
    const t = of.compiled.result(of.entry, name) orelse return null;
    return typeOf(gpa, project, of.compiled, t, 0);
}

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

/// Whether the compiled roots analyzed a declaration of a container: Zig emits an entry for
/// every container declaration it analyzed, whatever its kind (a `constant` or `variable`, an
/// `imported_declaration` for an alias or import, a structure, union or enumeration, a
/// `subprogram`, even for a type function or one called only at compile time), under its
/// container (`ZIG_parent`), and none for one it never analyzed.
pub const Reach = enum { held, not_reached };

/// Whether the compiled roots analyzed the container declaration `index` of `file`: held where
/// one emits it; not reached where none does (none holding the file is none emitting it, as for
/// `local`). Null where no root is given, where the declaration is no container's, or where a
/// root's entry for its container is not found: a container inside a function (each instance
/// has its own) or one whose own declaration is emitted but whose entry is not read.
pub fn declared(project: *const Project, compiled: []const *const Compiled, file: Project.FileId, index: Model.Declaration.Id) error{OutOfMemory}!?Reach {
    if (compiled.len == 0) return null;
    const source = project.at(file);
    const model = &source.model;
    const tree = &source.file.tree;
    const record = model.declarations[@backingInt(index)];
    if (record.kind != .variable and record.kind != .function) return null;
    switch (model.scopes[@backingInt(record.scope)].kind) {
        .file, .container => {},
        else => return null,
    }
    var unknown = false;
    for (compiled) |c| {
        const compiled_file = (try c.fileId(source.input.name)) orelse continue;
        const reach = reachIn(c, model, tree, compiled_file, record.scope, record.name, 0) orelse {
            unknown = true;
            continue;
        };
        if (reach == .held) return .held;
    }
    if (unknown) return null;
    return .not_reached;
}

/// Whether root `c` emits the declaration `name` of container `scope`. A container with no
/// entry of its own is not compiled where its own declaration is not.
fn reachIn(c: *const Compiled, model: *const Model, tree: *const Ast, file: u32, scope: Model.Scope.Id, name: []const u8, depth: u8) ?Reach {
    if (depth > 32) return null;
    if (containerEntry(c, model, tree, file, scope)) |container| return if (c.declaration(container, name) != null) .held else .not_reached;
    const outer = containerDeclaration(model, scope) orelse return null;
    const record = model.declarations[@backingInt(outer)];
    return switch (reachIn(c, model, tree, file, record.scope, record.name, depth + 1) orelse return null) {
        .held => null,
        .not_reached => .not_reached,
    };
}

/// Root `c`'s entry for container `scope`: the file's own structure, or the container declared
/// on its line. Null for a container inside a function, whose every instance has an entry of
/// its own, and where none is found.
fn containerEntry(c: *const Compiled, model: *const Model, tree: *const Ast, file: u32, scope: Model.Scope.Id) ?u32 {
    const s = model.scopes[@backingInt(scope)];
    if (s.kind == .file) return c.file_structs.get(file);
    if (s.kind != .container) return null;
    var at = s.parent;
    while (at) |id| : (at = model.scopes[@backingInt(id)].parent) {
        switch (model.scopes[@backingInt(id)].kind) {
            .file, .container => {},
            else => return null,
        }
    }
    return c.containers.get(.{ .file = file, .line = lineOf(tree, s.first) });
}

/// The declaration whose value is the container `scope` (`const Inner = struct { ... }`), in
/// the scope around it; null for any other container.
fn containerDeclaration(model: *const Model, scope: Model.Scope.Id) ?Model.Declaration.Id {
    const s = model.scopes[@backingInt(scope)];
    if (s.kind != .container) return null;
    const outer = s.parent orelse return null;
    const holder = model.parentOf(s.node) orelse return null;
    var names = model.scopes[@backingInt(outer)].names.valueIterator();
    while (names.next()) |id| {
        const record = model.declarations[@backingInt(id.*)];
        if (record.kind == .variable and record.node == holder) return id.*;
    }
    return null;
}

fn same(a: Type, b: Type) bool {
    return switch (a) {
        .primitive => |name| b == .primitive and std.mem.eql(u8, name, b.primitive),
        .pointer => |pointer| b == .pointer and pointer.size == b.pointer.size and same(pointer.child.*, b.pointer.child.*),
        .container => |container| b == .container and container.file == b.container.file and container.scope == b.container.scope,
        // One instance is one entry of one compilation: Zig makes one type per function and arguments.
        .instance => |inst| b == .instance and inst.compiled == b.instance.compiled and inst.entry == b.instance.entry,
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
/// file's own. A type function's instance is named with its arguments, at the line its every
/// instance shares, the line of the container the function returns: it is that container with
/// the compilation's entry (`Type.instance`), whose members' types carry the arguments.
fn containerOf(project: *const Project, c: *const Compiled, ty: u32) ?Type {
    const file = c.fileOf(ty);
    if (file == Compiled.none) return null;
    const project_file = projectFile(project, c.paths.keys()[file]) orelse return null;
    const source = project.at(project_file);
    const model = &source.model;
    const tree = &source.file.tree;
    if (c.placeOf(ty)) |place| {
        if (c.files[c.origin(ty)] == Compiled.none or c.dwarf.entries.items(.line)[c.origin(ty)] != 0) {
            for (model.scopes, 0..) |s, i| {
                if (s.kind != .container) continue;
                if (lineOf(tree, s.first) != place.line) continue;
                const scope: Model.Scope.Id = @fromBackingInt(@intCast(i)); // safe: scopes are counted in u32
                if (c.instance(ty)) return .{ .instance = .{ .file = project_file, .scope = scope, .compiled = c, .entry = ty } };
                return .{ .container = .{ .file = project_file, .scope = scope } };
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

test "a container declaration no compiled root emits is not reached; one it emits is held" {
    const gpa = std.testing.allocator;
    const bytes = try Compiled.Dwarf.sampleForTests(gpa);
    defer gpa.free(bytes);
    var c = try Compiled.init(gpa, try Compiled.Dwarf.readBytesForTests(bytes), "/pkg");
    defer c.deinit();
    // Lines as the sample declares them: List at 3, its method first at 5, Box(u32) at 9, width
    // at 10, Shape at 11; Gone, at 12, has no entry.
    const source =
        \\// s
        \\const std = @import("std");
        \\pub const List = struct {
        \\    len: usize,
        \\    pub fn first(n: usize) usize { return n; }
        \\    pub fn second() void {}
        \\};
        \\pub const unused: u32 = 1;
        \\fn Make(comptime T: type) type { return struct { pub const inside: T = 0; }; }
        \\pub const width: u32 = 7;
        \\pub const Shape = union(enum) { circle: usize, square: usize };
        \\pub const Gone = struct { pub const deep: u8 = 0; };
        \\pub const alias = List;
        \\
    ;
    var project = try Project.init(gpa, &.{.{ .name = "src/s.zig", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    const file = try project.fileAt(0);
    const model = &project.at(file).model;
    const roots: []const *const Compiled = &.{&c};
    const Case = struct { []const u8, ?Reach };
    for ([_]Case{
        .{ "width", .held },
        .{ "alias", .held },
        .{ "first", .held },
        .{ "second", .not_reached },
        .{ "unused", .not_reached },
        .{ "std", .not_reached },
        // A container no root emits: what it declares is not reached either.
        .{ "deep", .not_reached },
        // A container a function returns: each instance has its own entry.
        .{ "inside", null },
        // A function's parameter is no container's declaration.
        .{ "n", null },
    }) |case| {
        const index = for (model.declarations, 0..) |record, i| {
            if (std.mem.eql(u8, record.name, case[0])) break @as(Model.Declaration.Id, @fromBackingInt(@intCast(i))); // safe: a test's few declarations
        } else return error.TestUnexpectedResult;
        std.testing.expectEqual(case[1], try declared(&project, roots, file, index)) catch |err| {
            std.debug.print("{s}\n", .{case[0]});
            return err;
        };
    }
    try std.testing.expectEqual(@as(?Reach, null), try declared(&project, &.{}, file, @fromBackingInt(0)));
}
