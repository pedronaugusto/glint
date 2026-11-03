//! The construct matrix of `Facts.accesses`: each way a program writes or reads a place, an
//! unsafe probe whose site the query must find and a safe twin it must not.
const std = @import("std");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const Constructs = @import("Constructs.zig");
const accesses = Facts.accesses;

const Query = enum { writes, reads };
const Row = struct {
    name: []const u8,
    source: []const u8,
    /// A field's name, or a declaration's with `decl`.
    place: []const u8,
    decl: bool = false,
    query: Query = .writes,
    /// For a field's writes: whether whole values and outside code's writes are asked for.
    holders: bool = true,
    /// Each site found, as "line kind reach", with " part", " through", " deferred" as set.
    expected: []const []const u8,
};

const shapes = "const S = struct { f: u32 = 0, g: u32 = 0, a: [4]u8 = @splat(0) };\nconst T = struct { f: u32 = 0, g: u32 = 0 };\n";

const rows = [_]Row{
    .{ .name = "W1 x.f = v", .source = shapes ++ "fn w(s: *S) void {\n    s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W1 twin", .source = shapes ++ "fn w(s: *S) void {\n    s.g = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W1 x = v", .source = "fn w() void {\n    var x: u32 = 0;\n    x = 1;\n    var y: u32 = 0;\n    y = 2;\n}\n", .place = "x", .decl = true, .expected = &.{ "2 init exact", "3 set exact" } },
    .{ .name = "W2 op=", .source = shapes ++ "fn w(s: *S) void {\n    s.f += 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 update exact through" } },
    .{ .name = "W2 twin", .source = shapes ++ "fn w(s: *S) void {\n    s.g += 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W3 destructure", .source = shapes ++ "fn w(s: *S) void {\n    s.f, s.g = .{ 1, 2 };\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W3 twin", .source = shapes ++ "fn w(s: *S) void {\n    s.g, _ = .{ 1, 2 };\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W4 @field spelled", .source = shapes ++ "fn w(s: *S) void {\n    @field(s, \"f\") = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W4 twin", .source = shapes ++ "fn w(s: *S) void {\n    @field(s, \"g\") = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W4 @field computed", .source = shapes ++ "fn w(s: *S, comptime n: []const u8) void {\n    @field(s, n) = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set holder part through computed" } },
    .{ .name = "W4 computed twin", .source = shapes ++ "fn w(t: *T, comptime n: []const u8) void {\n    @field(t, n) = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W5 pointer capture", .source = shapes ++ "fn w(s: *S) void {\n    for (s.a) |*p| p.* = 0;\n}\n", .place = "a", .expected = &.{ "1 init exact", "4 address exact through" } },
    .{ .name = "W5 twin", .source = shapes ++ "fn w(s: *S) u8 {\n    var n: u8 = 0;\n    for (s.a) |p| n +%= p;\n    return n;\n}\n", .place = "a", .expected = &.{"1 init exact"} },
    .{ .name = "W5 written through", .source = shapes ++ "fn w(items: []S) void {\n    for (items) |*s| s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W6 address", .source = shapes ++ "fn w(s: *S) void {\n    const p = &s.f;\n    p.* = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 address exact through" } },
    .{ .name = "W6 twin", .source = shapes ++ "fn w(s: *S) void {\n    const p = &s.g;\n    p.* = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W8 whole store", .source = shapes ++ "fn w(s: *S, t: S) void {\n    s.* = t;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set holder through" } },
    .{ .name = "W8 twin", .source = shapes ++ "fn w(s: *T, t: T) void {\n    s.* = t;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W8 holder by value", .source = shapes ++ "const O = struct { inner: S };\nfn w(o: *O, t: O) void {\n    o.* = t;\n}\n", .place = "f", .expected = &.{ "1 init exact", "5 set holder through" } },
    .{ .name = "W8 holder by pointer twin", .source = shapes ++ "const O = struct { inner: *S };\nfn w(o: *O, t: O) void {\n    o.* = t;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W9 memcpy", .source = shapes ++ "fn w(d: []S, s: []const S) void {\n    @memcpy(d, s);\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set holder through" } },
    .{ .name = "W9 twin", .source = shapes ++ "fn w(d: []T, s: []const T) void {\n    @memcpy(d, s);\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W10 cast", .source = shapes ++ "fn w(b: *[12]u8) *S {\n    return @ptrCast(@alignCast(b));\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder" } },
    .{ .name = "W10 twin", .source = shapes ++ "fn w(b: *[8]u8) *T {\n    return @ptrCast(@alignCast(b));\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W11 outside call", .source = shapes ++ "extern fn ext(p: *S) void;\nfn w(s: *S) void {\n    ext(s);\n}\n", .place = "f", .expected = &.{ "1 init exact", "5 covered holder" } },
    .{ .name = "W11 twin", .source = shapes ++ "extern fn ext(p: *T) void;\nfn w(t: *T) void {\n    ext(t);\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W12 element", .source = shapes ++ "fn w(v: S) void {\n    var arr: [2]S = undefined;\n    arr[0] = v;\n}\n", .place = "arr", .decl = true, .expected = &.{ "4 init exact", "5 set exact part" } },
    .{ .name = "W12 element's field", .source = shapes ++ "fn w(v: S) void {\n    var arr: [2]S = undefined;\n    arr[0] = v;\n}\n", .place = "f", .expected = &.{ "1 init exact", "5 set holder" } },
    .{ .name = "W13 defer", .source = shapes ++ "fn w(s: *S) void {\n    defer s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through deferred" } },
    .{ .name = "W13 twin", .source = shapes ++ "fn w(s: *S) void {\n    defer s.g = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W14 asm", .source = shapes ++ "fn w() void {\n    asm volatile (\"\");\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered unresolved" } },
    .{ .name = "W14 twin", .source = shapes ++ "fn w() void {}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "unresolved holder", .source = shapes ++ "fn w(s: anytype) void {\n    s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set named" } },
    .{ .name = "unresolved holder twin", .source = shapes ++ "fn w(s: anytype) void {\n    s.g = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "literal", .source = shapes ++ "fn w() S {\n    return .{ .f = 1 };\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 init exact" } },
    .{ .name = "literal twin", .source = shapes ++ "fn w() S {\n    return .{ .g = 1 };\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "method receiver", .source = "const S = struct {\n    f: u32,\n    fn bump(self: *S) void {\n        self.f += 1;\n    }\n};\nfn w() void {\n    var s: S = .{ .f = 0 };\n    s.bump();\n}\n", .place = "s", .decl = true, .expected = &.{ "8 init exact", "9 address exact" } },
    .{ .name = "method receiver twin", .source = "const S = struct {\n    f: u32,\n    fn get(self: S) u32 {\n        return self.f;\n    }\n};\nfn w() u32 {\n    var s: S = .{ .f = 0 };\n    return s.get();\n}\n", .place = "s", .decl = true, .expected = &.{"8 init exact"} },
    // A field query that leaves out whole values (a function pointer's stores) still keeps
    // each site that may name the field without its spelling.
    .{ .name = "narrow: spelled", .holders = false, .source = shapes ++ "fn w(s: *S) void {\n    s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "narrow: other field", .holders = false, .source = shapes ++ "fn w(s: *S) void {\n    s.g = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "narrow: computed @field", .holders = false, .source = shapes ++ "fn w(s: *S, comptime n: []const u8) void {\n    @field(s, n) = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set holder part through computed" } },
    // A name a `const` holds is the name it spells (`Facts.fieldName`).
    .{ .name = "narrow: @field by a const", .holders = false, .source = shapes ++ "const name = \"f\";\nfn w(s: *S) void {\n    @field(s, name) = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "5 set exact through" } },
    .{ .name = "narrow: @field by a const twin", .holders = false, .source = shapes ++ "const name = \"g\";\nfn w(s: *S) void {\n    @field(s, name) = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "@field by an enum literal", .source = shapes ++ "fn w(s: *S) void {\n    @field(s, @tagName(.f)) = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "narrow: anytype holder", .holders = false, .source = shapes ++ "fn w(s: anytype) void {\n    s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set named" } },
    .{ .name = "narrow: cast", .holders = false, .source = shapes ++ "fn w(b: *[12]u8) *S {\n    return @ptrCast(@alignCast(b));\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder" } },
    .{ .name = "narrow: asm", .holders = false, .source = shapes ++ "fn w() void {\n    asm volatile (\"\");\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered unresolved" } },
    .{ .name = "narrow: address", .holders = false, .source = shapes ++ "fn w(s: *S) *u32 {\n    return &s.f;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 address exact through" } },
    // Left out by design there: a whole value copied, which carries what other stores gave.
    .{ .name = "narrow: whole store left out", .holders = false, .source = shapes ++ "fn w(s: *S, t: S) void {\n    s.* = t;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "R1 name", .source = "fn w() u32 {\n    const x: u32 = 1;\n    const z: u32 = 2;\n    _ = z;\n    return x;\n}\n", .place = "x", .decl = true, .query = .reads, .expected = &.{"5 read exact"} },
    .{ .name = "R2 member", .source = shapes ++ "fn w(s: S) u32 {\n    return s.f;\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read exact"} },
    .{ .name = "R2 twin", .source = shapes ++ "fn w(s: S) u32 {\n    return s.g;\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R3 @field", .source = shapes ++ "fn w(s: S) u32 {\n    return @field(s, \"f\");\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read exact"} },
    .{ .name = "R3 twin", .source = shapes ++ "fn w(s: S) u32 {\n    return @field(s, \"g\");\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R4 capture", .source = shapes ++ "fn w(items: []const S, out: *S) void {\n    for (items) |it| out.* = it;\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read holder"} },
    .{ .name = "R4 twin", .source = shapes ++ "fn w(items: []const T, out: *T) void {\n    for (items) |it| out.* = it;\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R5 copy", .source = shapes ++ "fn w(p: *const S) S {\n    return p.*;\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read holder"} },
    .{ .name = "R5 twin", .source = shapes ++ "fn w(p: *const T) T {\n    return p.*;\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R6 address", .source = "fn w() *const u32 {\n    const x: u32 = 1;\n    return &x;\n}\n", .place = "x", .decl = true, .expected = &.{ "2 init exact", "3 address exact" } },
    // An address taken reads the place as anything the pointer goes to may.
    .{ .name = "R6 address read", .source = "fn w() *const u32 {\n    const x: u32 = 1;\n    return &x;\n}\n", .place = "x", .decl = true, .query = .reads, .expected = &.{"3 address exact"} },
    .{ .name = "R6 member's address", .source = shapes ++ "fn w(s: *S) *u32 {\n    return &s.f;\n}\n", .place = "f", .query = .reads, .expected = &.{"4 address exact through"} },
    .{ .name = "R6 twin", .source = shapes ++ "fn w(s: *S) *u32 {\n    return &s.g;\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R7 memcpy source", .source = shapes ++ "fn w(d: []S, s: []const S) void {\n    @memcpy(d, s);\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read holder through"} },
    .{ .name = "R7 twin", .source = shapes ++ "fn w(d: []T, s: []const T) void {\n    @memcpy(d, s);\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R7 memcpy from an address", .source = shapes ++ "fn w(d: *[2]S) void {\n    const v: [2]S = undefined;\n    @memcpy(d, &v);\n}\n", .place = "v", .decl = true, .query = .reads, .expected = &.{ "5 address exact", "5 read exact" } },
    .{ .name = "R7 atomic load", .source = shapes ++ "fn w(s: *S) u32 {\n    return @atomicLoad(u32, &s.f, .seq_cst);\n}\n", .place = "f", .query = .reads, .expected = &.{ "4 address exact through", "4 read exact through" } },
    // A view of a parameter's memory (`std.mem.asBytes`) points at what its argument does.
    .{ .name = "R7 memcpy through a view", .source = "fn bytes(p: anytype) *const [4]u8 {\n    return @ptrCast(p);\n}\nfn w(d: *[4]u8) void {\n    const v: u32 = 1;\n    @memcpy(d, bytes(&v));\n}\n", .place = "v", .decl = true, .query = .reads, .expected = &.{ "6 address exact", "6 read exact" } },
    .{ .name = "R7 view twin", .source = "const table: [4]u8 = .{ 0, 0, 0, 0 };\nfn bytes(p: anytype) *const [4]u8 {\n    _ = p;\n    return &table;\n}\nfn w(d: *[4]u8) void {\n    const v: u32 = 1;\n    @memcpy(d, bytes(&v));\n}\n", .place = "v", .decl = true, .query = .reads, .expected = &.{"8 address exact"} },
    .{ .name = "W9 memcpy through a view", .source = "fn bytes(p: anytype) *[4]u8 {\n    return @ptrCast(p);\n}\nfn w(s: *const [4]u8) void {\n    var v: u32 = 1;\n    @memcpy(bytes(&v), s);\n}\n", .place = "v", .decl = true, .expected = &.{ "5 init exact", "6 address exact", "6 set exact" } },
    // A store through a view's result writes the memory it views, in part, as bytes: no one
    // value of its fields.
    .{ .name = "W7 store through a view", .source = shapes ++ "fn bytes(p: anytype) *[24]u8 {\n    return @ptrCast(p);\n}\nfn w(s: *S) void {\n    bytes(s)[0] = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder", "7 set holder part through" } },
    .{ .name = "W7 view twin", .source = shapes ++ "fn bytes(p: anytype) *[16]u8 {\n    return @ptrCast(p);\n}\nfn w(t: *T) void {\n    bytes(t)[0] = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W7 store through a constant view", .source = shapes ++ "fn bytes(p: anytype) *[24]u8 {\n    return @ptrCast(p);\n}\nfn w(s: *S) void {\n    const b = bytes(s);\n    b[0] = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder", "8 set holder part through" } },
    // A function returning a view's call is a view itself.
    .{ .name = "W9 memcpy through a composed view", .source = shapes ++ "fn bytes(p: anytype) *[24]u8 {\n    return @ptrCast(p);\n}\nfn view(s: *S) *[24]u8 {\n    return bytes(s);\n}\nfn w(s: *S, from: *const [24]u8) void {\n    @memcpy(view(s), from);\n}\n", .place = "f", .expected = &.{ "1 init exact", "10 set holder through", "4 covered holder" } },
    .{ .name = "W9 composed view's local", .source = "fn bytes(p: anytype) *[4]u8 {\n    return @ptrCast(p);\n}\nfn view(p: *u32) *[4]u8 {\n    return bytes(p);\n}\nfn w(s: *const [4]u8) void {\n    var v: u32 = 1;\n    @memcpy(view(&v), s);\n}\n", .place = "v", .decl = true, .expected = &.{ "8 init exact", "9 address exact", "9 set exact" } },
    // A typeless literal handed to code the program does not hold holds what its parts do.
    .{ .name = "W11 literal handed out", .source = shapes ++ "fn w(s: *S, f: anytype) void {\n    f(.{s});\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder" } },
    .{ .name = "W11 literal twin", .source = shapes ++ "fn w(s: *S, f: anytype) void {\n    f(.{s.g});\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "R7 atomic load twin", .source = shapes ++ "fn w(s: *S) u32 {\n    return @atomicLoad(u32, &s.g, .seq_cst);\n}\n", .place = "f", .query = .reads, .expected = &.{} },
};

fn found(a: std.mem.Allocator, project: *const Project, site: accesses.Site) ![]const u8 {
    const tree = &project.at(site.file).file.tree;
    const line = tree.tokenLocation(0, tree.firstToken(site.node)).line + 1;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{d} {t} {t}{s}{s}{s}{s}", .{ line, site.kind, site.reach, if (site.part) " part" else "", if (site.through) " through" else "", if (site.deferred) " deferred" else "", if (site.computed) " computed" else "" });
    return out.written();
}

fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

test "accesses: each construct's probe is found and its twin is not" {
    var failed = false;
    for (rows) |row| {
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = row.source }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var facts: Facts = .{ .project = &project, .gpa = a };
        defer facts.deinit();
        const file = project.sources[0].id;
        const model = &project.sources[0].model;
        const index = for (model.declarations, 0..) |d, i| {
            if (!std.mem.eql(u8, d.name, row.place)) continue;
            if ((d.kind == .field) != !row.decl) continue;
            break i;
        } else {
            std.debug.print("{s}: no place '{s}'\n", .{ row.name, row.place });
            failed = true;
            continue;
        };
        const decl: Facts.Decl = .{ .file = file, .index = @fromBackingInt(@intCast(index)) };
        const place: accesses.Place = if (row.decl) .{ .declaration = decl } else .{ .field = decl };
        const sites = switch (row.query) {
            .writes => try accesses.writesFor(&facts, place, &.{file}, .{ .holders = row.holders }),
            .reads => try accesses.reads(&facts, place, &.{file}),
        };
        var lines: std.ArrayList([]const u8) = .empty;
        for (sites) |site| try lines.append(a, try found(a, &project, site));
        std.mem.sort([]const u8, lines.items, {}, lessThan);
        const same = lines.items.len == row.expected.len and for (lines.items, row.expected) |got, want| {
            if (!std.mem.eql(u8, got, want)) break false;
        } else true;
        if (same) continue;
        failed = true;
        std.debug.print("{s}: expected", .{row.name});
        for (row.expected) |want| std.debug.print(" [{s}]", .{want});
        std.debug.print(", found", .{});
        for (lines.items) |got| std.debug.print(" [{s}]", .{got});
        std.debug.print("\n", .{});
    }
    try std.testing.expect(!failed);
}

test "accesses: a function copies memory between its parameters, or a value into one's, or reads one's out" {
    const source =
        \\fn copy(dest: []u8, source: []const u8) void {
        \\    for (dest[0..source.len], source) |*d, s| d.* = s;
        \\}
        \\fn back(dest: []u8, source: []const u8) void {
        \\    var i = source.len;
        \\    while (i > 0) {
        \\        i -= 1;
        \\        dest[i] = source[i];
        \\    }
        \\}
        \\fn swap(a: *u32, b: *u32) void {
        \\    const tmp = a.*;
        \\    a.* = b.*;
        \\    b.* = tmp;
        \\}
        \\fn read(bytes: *const [4]u8) u32 {
        \\    return @as(*const u32, @ptrCast(bytes)).*;
        \\}
        \\fn get(p: *const u32) u32 {
        \\    return p.*;
        \\}
        \\fn put(buffer: *[4]u8, value: u32, big: bool) void {
        \\    buffer.* = if (big) @bitCast(@byteSwap(value)) else @bitCast(value);
        \\}
        \\fn take(buffer: *const [4]u8, big: bool) u32 {
        \\    const raw: u32 = @bitCast(buffer.*);
        \\    return if (big) @byteSwap(raw) else raw;
        \\}
        \\fn wrap(d: []u8, s: []const u8) void {
        \\    copy(d, s);
        \\}
        \\
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const function = struct {
        fn named(p: *const Project, name: []const u8) Facts.Decl {
            for (p.sources[0].model.declarations, 0..) |d, i| {
                if (d.kind == .function and std.mem.eql(u8, d.name, name)) return .{ .file = p.sources[0].id, .index = @fromBackingInt(@intCast(i)) };
            }
            unreachable; // each name is declared above
        }
    };
    try std.testing.expectEqual(Facts.Copier{ .into = 0, .from = 1 }, (try facts.copierOf(function.named(&project, "copy"))).?);
    try std.testing.expectEqual(Facts.Copier{ .into = 0, .from = 1 }, (try facts.copierOf(function.named(&project, "back"))).?);
    try std.testing.expectEqual(Facts.Copier{ .into = 0, .from = 1, .exchange = true }, (try facts.copierOf(function.named(&project, "swap"))).?);
    try std.testing.expectEqual(Facts.Reader{ .from = 0, .recast = true }, (try facts.readOf(function.named(&project, "read"))).?);
    try std.testing.expectEqual(Facts.Reader{ .from = 0, .recast = false }, (try facts.readOf(function.named(&project, "get"))).?);
    try std.testing.expectEqual(Facts.Copier{ .into = 0, .from = 1 }, (try facts.copierOf(function.named(&project, "put"))).?);
    try std.testing.expectEqual(Facts.Reader{ .from = 0, .recast = true }, (try facts.readOf(function.named(&project, "take"))).?);
    try std.testing.expectEqual(Facts.Copier{ .into = 0, .from = 1 }, (try facts.copierOf(function.named(&project, "wrap"))).?);
}

test "accesses: each syntax form that holds an expression is in a construct matrix row its use is read as" {
    var failed = false;
    for (std.meta.tags(std.zig.Ast.Node.Tag)) |tag| {
        const row = Constructs.ofNode(tag) orelse {
            std.debug.print("{s}: in no row of the construct matrix\n", .{@tagName(tag)});
            failed = true;
            continue;
        };
        const form = accesses.formOf(tag);
        if (std.mem.findScalar(Constructs.Row, form.rows(), row) != null) continue;
        std.debug.print("{s}: row {s}, read as the form {s}\n", .{ @tagName(tag), @tagName(row), @tagName(form) });
        failed = true;
    }
    try std.testing.expect(!failed);
}

test "accesses: what an expression's value does where it stands" {
    // Each row: a source, the first expression spelled as `needle`, its use (a carried one with how).
    const rows_of_use = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "fn f() void { var x: u32 = 0; x = 1; }", "x", "written" },
        .{ "fn f(v: u32) void { var y: u32 = 0; y = v; }", "v", "stored" },
        .{ "fn f(v: u32) void { _ = v; }", "v", "discarded" },
        .{ "fn f() void { var x: u32 = 0; x += 1; }", "x", "updated" },
        .{ "fn f(v: u32) void { var x: u32 = 0; x += v; }", "v", "operand" },
        .{ "fn f(t: struct { u32, u32 }) void { var a: u32 = 0; var b: u32 = 0; a, b = t; }", "t", "destructured" },
        .{ "fn f(t: struct { u32, u32 }) void { var a: u32 = 0; var b: u32 = 0; a, b = t; }", "a", "written" },
        .{ "fn f() void { var a: [2]u32 = undefined; a[0] = 1; }", "a[0]", "written" },
        .{ "fn f() void { var a: [2]u32 = undefined; a[0] = 1; }", "a", "element" },
        .{ "fn f(s: struct { a: u32 }) u32 { return s.a; }", "s", "member" },
        .{ "fn f(s: [2]u32, i: usize) u32 { return s[i]; }", "i", "index" },
        .{ "fn f(s: []u32) []u32 { return s[1..]; }", "s", "sliced" },
        .{ "fn f(p: *u32) u32 { return p.*; }", "p", "dereferenced" },
        .{ "fn f(x: u32) *const u32 { return &x; }", "x", "address" },
        .{ "fn f(x: u32) bool { return x == 1; }", "x", "compared" },
        .{ "fn f(x: u32) u32 { return x + 1; }", "x", "operand" },
        .{ "fn f(x: []const u8) []const u8 { return x ++ \"a\"; }", "x", "concatenated" },
        .{ "fn f(x: ?u32) u32 { return x.?; }", "x", "carried unwrapped" },
        .{ "fn f(x: anyerror!u32) !u32 { return try x; }", "x", "carried tried" },
        .{ "fn f(x: ?u32) u32 { return x orelse 0; }", "x", "carried payload" },
        .{ "fn f(x: u32, y: ?u32) u32 { return y orelse x; }", "x", "carried otherwise" },
        .{ "fn f(x: anyerror!u32) u32 { return x catch 0; }", "x", "carried payload" },
        .{ "fn f(x: u32) u32 { return (x); }", "x", "carried grouped" },
        .{ "fn f(c: bool, x: u32) u32 { return if (c) x else 0; }", "x", "carried prong" },
        .{ "fn f(c: bool, x: u32) u32 { return if (c) x else 0; }", "c", "tested" },
        .{ "fn f(c: ?u32) void { while (c) |_| {} }", "c", "tested" },
        .{ "fn f(x: u32) u32 { return switch (x) { else => 0 }; }", "x", "switched" },
        .{ "fn f(k: u32, x: u32) u32 { return switch (k) { 1 => x, else => 0 }; }", "x", "carried prong" },
        .{ "fn f(k: u32, x: u32) u32 { return switch (k) { x => 1, else => 0 }; }", "x", "matched" },
        .{ "fn f(x: u32) u32 { return blk: { break :blk x; }; }", "x", "carried broken" },
        .{ "fn f(x: u32) u32 { return while (true) { break x; } else 0; }", "x", "carried broken" },
        .{ "fn f(x: u32) u32 { return outer: while (true) { while (true) break :outer x; } else 0; }", "x", "carried broken" },
        .{ "fn f(x: u32) u32 { return comptime x; }", "x", "carried compile_time" },
        .{ "fn f(x: []u32) void { for (x) |_| {} }", "x", "looped" },
        .{ "fn f(n: usize) void { for (0..n) |_| {} }", "n", "operand" },
        .{ "fn g(a: u32) void { _ = a; } fn f(x: u32) void { g(x); }", "x", "argument" },
        .{ "fn g(a: u32) void { _ = a; } fn f(x: u32) void { g(x); }", "g", "callee" },
        .{ "fn f(x: u32) u64 { return @as(u64, x); }", "x", "builtin_argument" },
        .{ "const S = struct { a: u32 }; fn f(x: u32) S { return .{ .a = x }; }", "x", "field_of" },
        .{ "fn f(x: u32) [1]u32 { return .{x}; }", "x", "element_of" },
        .{ "fn f(x: u32) void { const y = x; _ = y; }", "x", "initializes" },
        .{ "const S = struct { a: u32 = n }; const n: u32 = 1;", "n", "initializes" },
        .{ "fn f(x: u32) u32 { return x; }", "x", "returned" },
        .{ "fn f() void { var x: [n]u8 = undefined; _ = &x; } const n = 4;", "n", "typed" },
        .{ "fn g() void {} fn f() void { g(); }", "g()", "statement" },
        .{ "fn g() void {} fn f() void { defer g(); }", "g()", "statement" },
    };
    var failed = false;
    for (rows_of_use) |row| {
        const source, const needle, const want = row;
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var facts: Facts = .{ .project = &project, .gpa = a };
        defer facts.deinit();
        const file = project.sources[0].id;
        const tree = &project.sources[0].file.tree;
        const node = for (0..tree.nodes.len) |i| {
            const each: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (each != .root and std.mem.eql(u8, tree.getNodeSource(each), needle)) break each;
        } else {
            std.debug.print("{s}: no expression '{s}'\n", .{ source, needle });
            failed = true;
            continue;
        };
        const use = try accesses.useOf(&facts, file, node);
        const got = switch (use) {
            .carried => |carried| try std.fmt.allocPrint(a, "carried {s}", .{@tagName(carried.how)}),
            else => @tagName(use),
        };
        if (std.mem.eql(u8, got, want)) continue;
        std.debug.print("{s}: '{s}' expected {s}, found {s}\n", .{ source, needle, want, got });
        failed = true;
    }
    try std.testing.expect(!failed);
}

/// The first node of `tree` spelled `needle` (not the root), or null.
fn spelledNode(tree: *const std.zig.Ast, needle: []const u8, skip: usize) ?std.zig.Ast.Node.Index {
    var left = skip;
    for (0..tree.nodes.len) |i| {
        const each: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i));
        if (each == .root or !std.mem.eql(u8, tree.getNodeSource(each), needle)) continue;
        if (left == 0) return each;
        left -= 1;
    }
    return null;
}

test "accesses: a place's path, whether two name one place, a discarded value, a carried one" {
    const S = "const U = union { a: u32, b: u32 }; const S = struct { a: u32, b: [4]u32, u: U, p: *S };\n";
    // A source, two expressions (the second's occurrence), and samePlace's answer.
    const pairs = [_]struct { []const u8, []const u8, []const u8, usize, []const u8 }{
        .{ "fn f() void { var s: S = undefined; s.a = 1; s.a = 2; }", "s.a", "s.a", 1, "yes" },
        .{ "fn f() void { var s: S = undefined; s.a = 1; (s).b[0] = 2; }", "s.a", "(s).b[0]", 0, "no" },
        .{ "fn f() void { var s: S = undefined; s.b[0] = 1; s.b[1] = 2; }", "s.b[0]", "s.b[1]", 0, "no" },
        .{ "fn f() void { var s: S = undefined; s.b[0] = 1; s.b[0] = 2; }", "s.b[0]", "s.b[0]", 1, "yes" },
        .{ "fn f(i: usize) void { var s: S = undefined; s.b[i] = 1; s.b[i] = 2; }", "s.b[i]", "s.b[i]", 1, "yes" },
        .{ "fn f() void { var i: usize = 0; var s: S = undefined; s.b[i] = 1; i = 1; s.b[i] = 2; }", "s.b[i]", "s.b[i]", 1, "unknown" },
        .{ "fn f() void { var s: S = undefined; s.u.a = 1; s.u.b = 2; }", "s.u.a", "s.u.b", 0, "unknown" },
        .{ "fn f() void { var s: S = undefined; var t: S = undefined; s.a = 1; t.a = 2; }", "s.a", "t.a", 0, "no" },
        .{ "fn f(s: *S, t: *S) void { s.a = 1; t.a = 2; }", "s.a", "t.a", 0, "unknown" },
        .{ "fn f(s: *S) void { s.p.a = 1; s.p.*.a = 2; }", "s.p.a", "s.p.*.a", 0, "unknown" },
        .{ "fn g() S { return undefined; } fn f() void { g().a = 1; g().a = 2; }", "g().a", "g().a", 1, "unknown" },
    };
    var failed = false;
    for (pairs) |row| {
        const body, const first, const second, const skip, const want = row;
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ S, body });
        defer std.testing.allocator.free(source);
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
        defer facts.deinit();
        const tree = &project.sources[0].file.tree;
        const a = spelledNode(tree, first, 0) orelse return error.TestUnexpectedResult;
        const b = spelledNode(tree, second, skip) orelse return error.TestUnexpectedResult;
        const got = @tagName(try accesses.samePlace(&facts, project.sources[0].id, a, b));
        if (std.mem.eql(u8, got, want)) continue;
        std.debug.print("{s}: '{s}' and '{s}' expected {s}, found {s}\n", .{ body, first, second, want, got });
        failed = true;
    }
    try std.testing.expect(!failed);

    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = S ++ "fn f(s: *S, o: ?u32, d: u32) u32 { _ = d; s.b[1..][0] = 2; return (o.?); }" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    // `s.b[1..][0]`: an element of a slice of an array through the pointer `s`, from `s`.
    const path = try accesses.pathOf(&facts, file, spelledNode(tree, "s.b[1..][0]", 0).?);
    try std.testing.expectEqual(@as(usize, 4), path.steps.len);
    try std.testing.expectEqual(.index, path.steps[0].kind);
    try std.testing.expectEqual(.slice, path.steps[1].kind);
    try std.testing.expect(!path.steps[1].crosses);
    try std.testing.expectEqualStrings("b", path.steps[2].name.?);
    try std.testing.expect(path.steps[2].crosses);
    try std.testing.expectEqual(.root, path.steps[3].kind);
    try std.testing.expect(path.root == .decl);
    // `_ = d;` discards `d`; the store into the element discards nothing.
    const discard = spelledNode(tree, "_ = d", 0).?;
    try std.testing.expectEqualStrings("d", tree.getNodeSource((try accesses.discardedBy(&facts, file, discard)).?));
    try std.testing.expect(try accesses.discardedBy(&facts, file, spelledNode(tree, "s.b[1..][0] = 2", 0).?) == null);
    // `(o.?)` carries `o.?`, which carries `o`; `o` carries nothing.
    const grouped = spelledNode(tree, "(o.?)", 0).?;
    const unwrapped = accesses.carriedFrom(tree, grouped).?;
    try std.testing.expectEqualStrings("o.?", tree.getNodeSource(unwrapped));
    try std.testing.expectEqualStrings("o", tree.getNodeSource(accesses.carriedFrom(tree, unwrapped).?));
    try std.testing.expect(accesses.carriedFrom(tree, accesses.carriedFrom(tree, unwrapped).?) == null);
}

test "Facts.knownBool: a bool known as the program compiles" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "fn f(x: bool) void { _ = !true; _ = (true and true); _ = x; }" }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    try std.testing.expectEqual(@as(?bool, false), try facts.knownBool(file, spelledNode(tree, "!true", 0).?));
    try std.testing.expectEqual(@as(?bool, true), try facts.knownBool(file, spelledNode(tree, "(true and true)", 0).?));
    try std.testing.expectEqual(@as(?bool, null), try facts.knownBool(file, spelledNode(tree, "x", 0).?));
}
