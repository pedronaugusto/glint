//! What a compilation of the program established, read from the DWARF Zig wrote for it
//! (`zig-0.17/Dwarf.zig`), indexed by what glint asks: a declaration by its file and line, the
//! instances compiled of it, each instance's locals and parameters with their types, a
//! container's declarations and members, and an inlined call by its line and column. Glint
//! infers no type: a type is the compiler's or unknown, and a declaration no compiled root
//! holds is not reached. Files are named relative to the package's root, as glint names its
//! inputs; a file outside it keeps its absolute path.
const std = @import("std");
const aegis = @import("aegis");
pub const Dwarf = @import("zig-0.17/Dwarf.zig");
const Compiled = @This();

pub const none = Dwarf.none;

gpa: std.mem.Allocator,
dwarf: Dwarf,
/// The package's directory, absolute, resolved: the paths under it are named relative to it.
root: []const u8,
/// Each file's path, relative to the package's root where it is under it, by id.
paths: std.array_hash_map.String(void),
/// Each entry's file, by id into `paths`; `none` where it names none.
files: []const u32,
/// Each declaration of a function, by its file and line: its origins (the abstract entry each
/// instance names), and whether any instance has code.
functions: std.AutoHashMapUnmanaged(Place, Function),
/// Each function origin's locals and parameters, by name: the types its instances give them.
locals: std.AutoHashMapUnmanaged(u32, Names),
/// Each container's declarations by name (`ZIG_parent`): its functions, its constants and
/// variables, its nested containers. An instance's method, which names only its origin, is
/// named by the origin's name.
decls: std.AutoHashMapUnmanaged(u32, Names),
/// Each structure's and union's members by name, with their types.
members: std.AutoHashMapUnmanaged(u32, Names),
/// Each file's own structure, by file id.
file_structs: std.AutoHashMapUnmanaged(u32, u32),
/// Each module's root structure, by the module's name.
module_roots: std.array_hash_map.String(u32),
/// Each container declared on a line (`const X = struct {`), by its file and line.
containers: std.AutoHashMapUnmanaged(Place, u32),
/// Each inlined call's callee origin, by its file, line and column.
inlined: std.AutoHashMapUnmanaged(Site, u32),

pub const Place = struct { file: u32, line: u32 };
pub const Site = struct { file: u32, line: u32, column: u32 };
pub const Function = struct { origins: std.ArrayList(u32) = .empty, code: bool = false };
/// Names to entries: a declaration, a member's type, a local's types.
pub const Names = std.array_hash_map.String(std.ArrayList(u32));

/// Indexes `dwarf`, which it then owns. `root` is the package's directory, absolute: a file
/// under it is named relative to it.
pub fn init(gpa: std.mem.Allocator, dwarf: Dwarf, root: []const u8) error{OutOfMemory}!Compiled {
    const resolved_root = std.fs.path.resolveAllocPosix(gpa, &.{root}) catch |err| {
        var owned = dwarf;
        owned.deinit(gpa);
        return err;
    };
    var c: Compiled = .{
        .gpa = gpa,
        .dwarf = dwarf,
        .root = resolved_root,
        .paths = .empty,
        .files = &.{},
        .functions = .empty,
        .locals = .empty,
        .decls = .empty,
        .members = .empty,
        .file_structs = .empty,
        .module_roots = .empty,
        .containers = .empty,
        .inlined = .empty,
    };
    errdefer c.deinit();
    try c.build();
    return c;
}

pub fn deinit(c: *Compiled) void {
    const gpa = c.gpa;
    for (c.paths.keys()) |p| gpa.free(p);
    c.paths.deinit(gpa);
    gpa.free(c.files);
    var functions = c.functions.valueIterator();
    while (functions.next()) |f| f.origins.deinit(gpa);
    c.functions.deinit(gpa);
    inline for (.{ &c.locals, &c.decls, &c.members }) |table| {
        var it = table.valueIterator();
        while (it.next()) |names| freeNames(gpa, names);
        table.deinit(gpa);
    }
    c.file_structs.deinit(gpa);
    c.module_roots.deinit(gpa);
    c.containers.deinit(gpa);
    c.inlined.deinit(gpa);
    c.dwarf.deinit(gpa);
    gpa.free(c.root);
}

fn freeNames(gpa: std.mem.Allocator, names: *Names) void {
    for (names.values()) |*list| list.deinit(gpa);
    names.deinit(gpa);
}

/// The id of `path`, as glint names the file, or null where no entry names it.
/// The id of the file at `path`: relative to the package's root as the compilation's are named,
/// or absolute, resolved and named relative to the root where it is under it.
pub fn fileId(c: *const Compiled, path: []const u8) error{OutOfMemory}!?u32 {
    if (c.paths.getIndex(path)) |index| return @intCast(index); // safe: paths are counted in u32, as `files` holds them
    if (!std.fs.path.isAbsolutePosix(path)) return null;
    const resolved = try std.fs.path.resolveAllocPosix(c.gpa, &.{path});
    defer c.gpa.free(resolved);
    const index = c.paths.getIndex(relative(c.root, resolved)) orelse return null;
    return @intCast(index); // safe: as above
}

/// The entry `offset` refers to, by index; null for none or one not kept.
pub fn entry(c: *const Compiled, offset: u32) ?u32 {
    return c.dwarf.at(offset);
}

/// The entry an instance is of: its abstract origin or specification, followed to the end.
pub fn origin(c: *const Compiled, start: u32) u32 {
    const e = c.dwarf.entries.slice();
    var index = start;
    for (0..16) |_| {
        const next_offset = if (e.items(.abstract_origin)[index] != none) e.items(.abstract_origin)[index] else e.items(.specification)[index];
        const next = c.dwarf.at(next_offset) orelse return index;
        if (next == index) return index;
        index = next;
    }
    return index;
}

/// Whether a function declared at `file`:`line` was compiled to code by any root.
pub fn compiled(c: *const Compiled, place: Place) bool {
    const f = c.functions.getPtr(place) orelse return false;
    return f.code;
}

/// Whether anything declared at `file`:`line` is held: a function analysed or compiled, or a
/// container.
pub fn holds(c: *const Compiled, place: Place) bool {
    return c.functions.contains(place) or c.containers.contains(place);
}

/// The types the instances of the function declared at `place` give its local or parameter
/// `name`, as entries; empty where none holds it.
pub fn localTypes(c: *const Compiled, gpa: std.mem.Allocator, place: Place, name: []const u8) error{OutOfMemory}![]const u32 {
    const f = c.functions.getPtr(place) orelse return &.{};
    var found: std.ArrayList(u32) = .empty;
    for (f.origins.items) |o| {
        const names = c.locals.getPtr(o) orelse continue;
        const types = names.getPtr(name) orelse continue;
        for (types.items) |t| if (std.mem.findScalar(u32, found.items, t) == null) try found.append(gpa, t);
    }
    return found.toOwnedSlice(gpa);
}

/// `ty` with its typedefs and qualifiers read through, and with `deref` its single pointers:
/// what a member access reads the members of.
pub fn strip(c: *const Compiled, ty: u32, deref: bool) u32 {
    const e = c.dwarf.entries.slice();
    var index = ty;
    for (0..32) |_| {
        switch (e.items(.kind)[index]) {
            .typedef, .@"const", .@"volatile" => {},
            .pointer => if (!deref) return index,
            else => return index,
        }
        index = c.dwarf.at(e.items(.type)[index]) orelse return index;
    }
    return index;
}

/// The type of `container`'s member `name`, or null where it has none.
pub fn member(c: *const Compiled, container: u32, name: []const u8) ?u32 {
    const names = c.members.getPtr(container) orelse return null;
    const list = names.getPtr(name) orelse return null;
    return if (list.items.len > 0) list.items[0] else null;
}

/// `container`'s declaration `name`, or null where it declares none the compilation emitted.
pub fn declaration(c: *const Compiled, container: u32, name: []const u8) ?u32 {
    const names = c.decls.getPtr(container) orelse return null;
    const list = names.getPtr(name) orelse return null;
    return if (list.items.len > 0) list.items[0] else null;
}

/// The file and line an entry is declared at: its own, or its origin's, its file read through
/// its containers. Null where neither is known.
pub fn placeOf(c: *const Compiled, index: u32) ?Place {
    const o = c.origin(index);
    const line = c.dwarf.entries.items(.line)[o];
    if (line == 0) return null;
    const file = c.fileOf(o);
    if (file == none) return null;
    return .{ .file = file, .line = line };
}

/// The file of an entry: its own, else its container's (`ZIG_parent`), followed out.
pub fn fileOf(c: *const Compiled, start: u32) u32 {
    const e = c.dwarf.entries.slice();
    var index = start;
    for (0..32) |_| {
        if (c.files[index] != none) return c.files[index];
        index = c.dwarf.at(e.items(.zig_parent)[index]) orelse return none;
    }
    return none;
}

/// Whether `name` is one Zig gives a file's own structure: a module-qualified path, never an
/// instance's arguments or a function's anonymous structure.
fn fileStructName(name: []const u8) bool {
    return name.len != 0 and std.mem.findScalar(u8, name, '(') == null and std.mem.find(u8, name, "__struct_") == null;
}

fn build(c: *Compiled) error{OutOfMemory}!void {
    const gpa = c.gpa;
    const e = c.dwarf.entries.slice();
    const count = e.len;
    // Files.
    const files = try gpa.alloc(u32, count);
    c.files = files;
    var per_unit: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer per_unit.deinit(gpa);
    for (files, e.items(.unit), e.items(.file)) |*f, unit, file| {
        f.* = none;
        if (file == none) continue;
        const key = (@as(u64, unit) << 32) | file;
        const got = try per_unit.getOrPut(gpa, key);
        if (!got.found_existing) {
            got.value_ptr.* = none;
            if (c.dwarf.path(unit, file)) |p| {
                // A module's path may climb (`.zig-cache/bay/../../src`): named as resolved.
                const resolved = try std.fs.path.resolveAllocPosix(gpa, &.{p});
                defer gpa.free(resolved);
                got.value_ptr.* = try c.intern(relative(c.root, resolved));
            }
        }
        f.* = got.value_ptr.*;
    }
    const kinds = e.items(.kind);
    const names = e.items(.name);
    const parents = e.items(.parent);
    for (0..count) |i_usize| {
        const i: u32 = @intCast(i_usize); // safe: entries are counted in u32
        switch (kinds[i]) {
            .structure, .@"union", .enumeration => {
                // A file's structure names its file and no line, under a dotted path: a type
                // function's instance (`Keyed(.x)`) and a function's anonymous structure
                // (`initialGroups__struct_4146`) name their file and no line too. A module's root
                // is the one the module's entry encloses under the module's name.
                if (e.items(.line)[i] == 0 and e.items(.zig_parent)[i] == none and files[i] != none and fileStructName(names[i])) {
                    _ = try c.file_structs.getOrPutValue(gpa, files[i], i);
                    const p = parents[i];
                    if (p != none and kinds[p] == .module and std.mem.eql(u8, names[p], names[i])) _ = try c.module_roots.getOrPutValue(gpa, names[i], i);
                }
                if (e.items(.line)[i] != 0) if (c.placeOf(i)) |place| {
                    _ = try c.containers.getOrPutValue(gpa, place, i);
                };
            },
            .member => if (parents[i] != none and names[i].len != 0) {
                if (c.dwarf.at(e.items(.type)[i])) |t| try add(gpa, &c.members, parents[i], names[i], t);
            },
            .subprogram => {
                const o = c.origin(i);
                if (c.placeOf(o)) |place| {
                    const got = try c.functions.getOrPut(gpa, place);
                    if (!got.found_existing) got.value_ptr.* = .{};
                    if (std.mem.findScalar(u32, got.value_ptr.origins.items, o) == null) try got.value_ptr.origins.append(gpa, o);
                    if (e.items(.code)[i]) got.value_ptr.code = true;
                }
            },
            .inlined => {
                const o = c.origin(i);
                if (c.placeOf(o)) |place| {
                    const got = try c.functions.getOrPut(gpa, place);
                    if (!got.found_existing) got.value_ptr.* = .{};
                    got.value_ptr.code = true;
                }
                // The call is in the file of the function it is inlined into.
                if (e.items(.call_line)[i] != 0) if (enclosingFunction(c, parents[i])) |caller| {
                    const file = c.fileOf(c.origin(caller));
                    if (file != none) _ = try c.inlined.getOrPutValue(gpa, .{ .file = file, .line = e.items(.call_line)[i], .column = e.items(.call_column)[i] }, o);
                };
            },
            .parameter, .variable => if (e.items(.zig_parent)[i] == none) {
                // A local or parameter: its name and type may be its origin's.
                var name = names[i];
                var ty = e.items(.type)[i];
                if (c.dwarf.at(e.items(.abstract_origin)[i])) |o| {
                    if (name.len == 0) name = names[o];
                    if (ty == none) ty = e.items(.type)[o];
                }
                const t = c.dwarf.at(ty) orelse continue;
                if (name.len == 0) continue;
                const owner = enclosingFunction(c, parents[i]) orelse continue;
                try add(gpa, &c.locals, c.origin(owner), name, t);
            },
            else => {},
        }
        // A declaration of a container: named, or a method named by its origin.
        const zp = c.dwarf.at(e.items(.zig_parent)[i]) orelse continue;
        var name = names[i];
        if (name.len == 0) name = names[c.origin(i)];
        if (name.len == 0) continue;
        try add(gpa, &c.decls, zp, name, i);
    }
}

/// The nearest function or inlined call enclosing `start`, by index, `start` among them.
fn enclosingFunction(c: *const Compiled, start: u32) ?u32 {
    const e = c.dwarf.entries.slice();
    var index_at = start;
    for (0..4096) |_| {
        if (index_at == none) return null;
        switch (e.items(.kind)[index_at]) {
            .subprogram => return index_at,
            .inlined => return c.dwarf.at(e.items(.abstract_origin)[index_at]) orelse index_at,
            else => index_at = e.items(.parent)[index_at],
        }
    }
    return null;
}

fn add(gpa: std.mem.Allocator, table: *std.AutoHashMapUnmanaged(u32, Names), key: u32, name: []const u8, value: u32) error{OutOfMemory}!void {
    const got = try table.getOrPut(gpa, key);
    if (!got.found_existing) got.value_ptr.* = .empty;
    const list = try got.value_ptr.getOrPut(gpa, name);
    if (!list.found_existing) list.value_ptr.* = .empty;
    if (std.mem.findScalar(u32, list.value_ptr.items, value) == null) try list.value_ptr.append(gpa, value);
}

fn intern(c: *Compiled, path: []const u8) error{OutOfMemory}!u32 {
    if (c.paths.getIndex(path)) |i| return @intCast(i); // safe: paths are counted in u32
    const owned = try c.gpa.dupe(u8, path);
    errdefer c.gpa.free(owned);
    try c.paths.put(c.gpa, owned, {});
    return aegis.int.narrow(u32, c.paths.count() - 1) orelse error.OutOfMemory;
}

/// `path` relative to `root` where it is under it; itself otherwise.
fn relative(root: []const u8, path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, root, "/");
    if (trimmed.len == 0 or path.len <= trimmed.len + 1) return path;
    if (!std.mem.startsWith(u8, path, trimmed) or path[trimmed.len] != '/') return path;
    return path[trimmed.len + 1 ..];
}

test "a sample's declarations, instances, locals, members and container declarations, by file and line" {
    const gpa = std.testing.allocator;
    const bytes = try Dwarf.sampleForTests(gpa);
    defer gpa.free(bytes);
    const d = try Dwarf.readBytesForTests(bytes);
    var c = try init(gpa, d, "/pkg");
    defer c.deinit();
    const file = (try c.fileId("src/s.zig")).?;
    // An input named absolute, or climbing, is the same file under the root.
    try std.testing.expectEqual(file, (try c.fileId("/pkg/src/s.zig")).?);
    try std.testing.expectEqual(file, (try c.fileId("/pkg/x/../src/s.zig")).?);
    try std.testing.expect(c.compiled(.{ .file = file, .line = 5 }));
    try std.testing.expect(!c.compiled(.{ .file = file, .line = 6 }));
    const n = try c.localTypes(gpa, .{ .file = file, .line = 5 }, "n");
    defer gpa.free(n);
    try std.testing.expectEqual(@as(usize, 1), n.len);
    try std.testing.expectEqualStrings("usize", c.dwarf.entries.items(.name)[n[0]]);
    // The block's local is the function's.
    const x = try c.localTypes(gpa, .{ .file = file, .line = 5 }, "x");
    defer gpa.free(x);
    try std.testing.expectEqual(@as(usize, 1), x.len);
    const list = c.containers.get(.{ .file = file, .line = 3 }).?;
    try std.testing.expectEqualStrings("usize", c.dwarf.entries.items(.name)[c.member(list, "len").?]);
    try std.testing.expectEqual(@as(?u32, null), c.member(list, "cap"));
    try std.testing.expectEqualStrings("first", c.dwarf.entries.items(.name)[c.declaration(list, "first").?]);
    const s = c.file_structs.get(file).?;
    try std.testing.expectEqualStrings("width", c.dwarf.entries.items(.name)[c.declaration(s, "width").?]);
    try std.testing.expectEqual(@as(?u32, null), try c.fileId("other.zig"));
    try std.testing.expectEqual(@as(?u32, null), try c.fileId("/elsewhere/src/s.zig"));
}
