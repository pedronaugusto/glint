//! The construct matrix of `Facts.accesses`: each way a program writes or reads a place, an
//! unsafe probe whose site the query must find and a safe twin it must not.
const std = @import("std");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
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
    .{ .name = "W10 cast as an error union's payload", .source = shapes ++ "fn w(b: *[12]u8) error{E}!*S {\n    return @ptrCast(@alignCast(b));\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder" } },
    .{ .name = "W10 cast as an error union's optional's payload", .source = shapes ++ "fn w(b: *[12]u8) error{E}!?*S {\n    return @ptrCast(@alignCast(b));\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder" } },
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
    .{ .name = "address of a literal", .source = shapes ++ "fn w() void {\n    const t: []const u32 = &.{};\n    _ = t;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "address of a literal's field", .source = shapes ++ "fn w() void {\n    const p = &S{};\n    _ = p;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "address held in a literal", .source = "fn w() void {\n    var x: u32 = 0;\n    const t: []const *u32 = &.{&x};\n    _ = t;\n}\n", .place = "x", .decl = true, .expected = &.{ "2 init exact", "3 address exact" } },
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
        const in_file = [_]Project.FileId{file};
        var sites = switch (row.query) {
            .writes => accesses.writesFor(&facts, place, &in_file, .{ .holders = row.holders }),
            .reads => accesses.reads(&facts, place, &in_file),
        };
        var lines: std.ArrayList([]const u8) = .empty;
        while (try sites.next()) |site| try lines.append(a, try found(a, &project, site));
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

test "accesses: an operator's operation by its tag, each form's overflow, and null for what is no arithmetic" {
    const Tag = std.zig.Ast.Node.Tag;
    // Both directions against `formOf`: a tag of the operator forms is read by `operatorOf` unless
    // it is an operator on one number (`-`, `-%`, `~`), a compound assignment always; every other
    // tag never.
    for (std.meta.tags(Tag)) |tag| {
        const binary = accesses.operatorOf(tag) != null;
        const unary = tag == .negation or tag == .negation_wrap or tag == .bit_not;
        switch (accesses.formOf(tag)) {
            .operator => try std.testing.expect(binary != unary),
            .compound_assign => try std.testing.expect(binary and !unary),
            else => try std.testing.expect(!binary and !unary),
        }
    }
    // A form and its assignment are one operation, whose overflow each carries.
    const Row2 = struct { Tag, Tag, @TypeOf(@as(accesses.Operator, undefined).op), @TypeOf(@as(accesses.Operator, undefined).overflow) };
    const operators = [_]Row2{
        .{ .add, .assign_add, .add, .checked },
        .{ .sub, .assign_sub, .sub, .checked },
        .{ .mul, .assign_mul, .mul, .checked },
        .{ .div, .assign_div, .div, .checked },
        .{ .mod, .assign_mod, .mod, .checked },
        .{ .shl, .assign_shl, .shl, .checked },
        .{ .shr, .assign_shr, .shr, .checked },
        .{ .bit_and, .assign_bit_and, .bit_and, .checked },
        .{ .bit_or, .assign_bit_or, .bit_or, .checked },
        .{ .bit_xor, .assign_bit_xor, .bit_xor, .checked },
        .{ .add_wrap, .assign_add_wrap, .add, .wrapping },
        .{ .sub_wrap, .assign_sub_wrap, .sub, .wrapping },
        .{ .mul_wrap, .assign_mul_wrap, .mul, .wrapping },
        .{ .add_sat, .assign_add_sat, .add, .saturating },
        .{ .sub_sat, .assign_sub_sat, .sub, .saturating },
        .{ .mul_sat, .assign_mul_sat, .mul, .saturating },
        .{ .shl_sat, .assign_shl_sat, .shl, .saturating },
    };
    for (operators) |row| for ([_]Tag{ row[0], row[1] }) |tag| {
        const read = accesses.operatorOf(tag).?; // unreachable: the first loop holds these to one
        try std.testing.expectEqual(row[2], read.op);
        try std.testing.expectEqual(row[3], read.overflow);
    };
    // What is no arithmetic, however an operator it looks: a condition's, a comparison's, a
    // pointer's and a type's.
    for ([_]Tag{ .bool_not, .bool_and, .bool_or, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .address_of, .deref, .optional_type, .assign, .assign_destructure }) |tag| {
        try std.testing.expectEqual(@as(?accesses.Operator, null), accesses.operatorOf(tag));
    }
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
        .{ "fn f() void { var x: [n]u8 = undefined; _ = &x; } const n = 4;", "n", "typed length" },
        .{ "fn f(x: *u32) void { _ = x; }", "u32", "typed pointer_child" },
        .{ "fn f(x: ?u8) void { _ = x; }", "u8", "typed optional_child" },
        .{ "fn f() anyerror!u8 { return 0; }", "u8", "typed error_payload" },
        .{ "fn f() anyerror!u8 { return 0; }", "anyerror", "typed error_set" },
        .{ "fn f(x: u8) void { _ = x; }", "u8", "typed parameter" },
        .{ "fn f() u8 { return 0; }", "u8", "typed result" },
        .{ "const x: u8 = 0;", "u8", "typed declared" },
        .{ "fn f(x: [4:0]u8) void { _ = x; }", "u8", "typed array_element" },
        .{ "fn f(a: bool, b: bool) bool { return a and b; }", "a", "logic left" },
        .{ "fn f(a: bool, b: bool) bool { return a or b; }", "b", "logic right" },
        .{ "fn f(a: bool) bool { return !a; }", "a", "logic negated" },
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
        // A use with a part is written with it: `carried grouped`.
        const kind = @tagName(use);
        const detail: []const u8 = switch (use) {
            .carried => |carried| @tagName(carried.how),
            .typed => |typed| @tagName(typed.part),
            .logic => |logic| @tagName(logic.side),
            else => "",
        };
        const matches = if (detail.len == 0)
            std.mem.eql(u8, want, kind)
        else
            want.len == kind.len + 1 + detail.len and std.mem.startsWith(u8, want, kind) and want[kind.len] == ' ' and std.mem.endsWith(u8, want, detail);
        if (matches) continue;
        std.debug.print("{s}: '{s}' expected {s}, found {s} {s}\n", .{ source, needle, want, kind, detail });
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
    const place_types = "const U = union { a: u32, b: u32 }; const S = struct { a: u32, b: [4]u32, u: U, p: *S };\n";
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
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ place_types, body });
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

    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = place_types ++ "fn f(s: *S, o: ?u32, d: u32) u32 { _ = d; s.b[1..][0] = 2; return (o.?); }" }}, &.{}, .{});
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
}

test "Facts: an enum's and a union's tags written with no type are members" {
    const source = "pub const E = enum(u8) { a, b = 2 }; pub const U = union(enum) { a, c: u32 }; pub const S = struct { a: u32 };\n" ++
        "fn f(u: U) void { _ = E.a; _ = u.a; }";
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const e = (try facts.declaration(facts.member(facts.rootOf(file), "E").?)).container;
    const u = (try facts.declaration(facts.member(facts.rootOf(file), "U").?)).container;
    const s = (try facts.declaration(facts.member(facts.rootOf(file), "S").?)).container;
    try std.testing.expect(facts.member(e, "a") != null);
    try std.testing.expect(facts.member(u, "a") != null);
    try std.testing.expect(facts.declaresTag(e, "a") and facts.declaresTag(e, "b") and facts.declaresTag(u, "a") and facts.declaresTag(u, "c"));
    try std.testing.expect(!facts.declaresTag(s, "a"));
    // `E.a` is a value of `E`; a union's tag with no type holds `void`.
    const tag = try facts.resolve(file, spelledNode(tree, "E.a", 0).?);
    try std.testing.expect(tag == .instance and std.meta.eql(tag.instance.scope, e.scope));
    try std.testing.expect(try facts.resolve(file, spelledNode(tree, "u.a", 0).?) == .scalar);
    try std.testing.expect(try facts.declaration(facts.member(e, "a").?) == .instance);
    // An enum's value holds no field.
    try std.testing.expectEqual(@as(usize, 0), (try facts.heldFields(e)).len);
}

test "Facts.literalType: a switch case's item is of what the switch tests, its body of the switch's place" {
    const source = "pub const U = union(enum) { compare: u32, skip }; pub const R = struct { compare: u32 };\n" ++
        "fn f(u: U) u32 { switch (u) { .compare => |n| return n, .skip => {} } return 0; }\n" ++
        "fn g(u: U) R { return switch (u) { .compare => .{ .compare = 1 }, .skip => .{ .compare = 0 } }; }";
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const u = (try facts.declaration(facts.member(facts.rootOf(file), "U").?)).container;
    const r = (try facts.declaration(facts.member(facts.rootOf(file), "R").?)).container;
    const tag = facts.member(u, "compare").?;
    // A statement's switch: the item names the tested union's tag.
    try std.testing.expectEqual(Facts.Named{ .decl = tag }, try facts.literalDeclaration(file, spelledNode(tree, ".compare", 0).?, "compare"));
    // A switch giving an `R`: its item is still the union's tag; its body's literal is an `R`.
    try std.testing.expectEqual(Facts.Named{ .decl = tag }, try facts.literalDeclaration(file, spelledNode(tree, ".compare", 1).?, "compare"));
    const made = try facts.literalType(file, spelledNode(tree, ".{ .compare = 1 }", 0).?);
    try std.testing.expect(made == .container and std.meta.eql(made.container.scope, r.scope));
}

test "Facts.literalType: `&.{}` is what its place points at, a slice's an array of the element; try and comptime give their operand their place" {
    const source =
        \\pub const A = struct {
        \\    in: []const u8 = &.{},
        \\    pub fn of(n: u32) A {
        \\        _ = n;
        \\        return .{};
        \\    }
        \\    pub fn ofError(n: u32) !A {
        \\        return .of(n);
        \\    }
        \\};
        \\pub const B = struct { in: []const u8 = &.{} };
        \\pub const D = switch (@import("builtin").os.tag) {
        \\    .wasi => noreturn,
        \\    .windows => A,
        \\    else => B,
        \\};
        \\fn take(o: *const D) void {
        \\    _ = o;
        \\}
        \\pub const C = struct { arg: ?*anyopaque };
        \\pub const E = switch (@import("builtin").os.tag) {
        \\    .windows => A,
        \\    else => C,
        \\};
        \\fn control(o: *const E) void {
        \\    _ = o;
        \\}
        \\fn each(xs: []const A) void {
        \\    _ = xs;
        \\}
        \\fn STRING(comptime T: type) type {
        \\    return struct { Buffer: ?[*]T };
        \\}
        \\pub const WIDE = STRING(u16);
        \\pub const NARROW = STRING(u8);
        \\fn wide(p: *anyopaque) WIDE {
        \\    return .{ .Buffer = @ptrCast(@alignCast(p)) };
        \\}
        \\fn f() !void {
        \\    take(&.{ .in = "x" });
        \\    control(&.{ .in = "z" });
        \\    each(&.{.{ .in = "y" }});
        \\    const a: A = comptime .of(1);
        \\    const b: A = try .ofError(2);
        \\    _ = .{ a, b };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const a = (try facts.declaration(facts.member(facts.rootOf(file), "A").?)).container;
    // A field of a literal under `&`, its place a pointer to a type chosen per target: each
    // choice's own field, here a `[]const u8` in both.
    const field = try facts.literalType(file, spelledNode(tree, "\"x\"", 0).?);
    try std.testing.expect(field == .pointer and field.pointer.child.* == .primitive);
    // A choice whose other struct has no `in` (a non-Windows `DeviceIoControl`): a build that
    // takes it does not compile the literal, so the field is the one choice's.
    const only = try facts.literalType(file, spelledNode(tree, "\"z\"", 0).?);
    try std.testing.expect(only == .pointer and only.pointer.child.* == .primitive);
    // `&.{ … }` where a `[]const A` is taken: an array of `A`, each element an `A`.
    const element = try facts.literalType(file, spelledNode(tree, ".{ .in = \"y\" }", 0).?);
    try std.testing.expect(element == .container and std.meta.eql(element.container.scope, a.scope));
    // A returned literal's field, of a container a type function made: its type with the
    // call's arguments, `?[*]u16` (another call makes `?[*]u8`).
    const buffer = try facts.literalType(file, spelledNode(tree, "@ptrCast(@alignCast(p))", 0).?);
    try std.testing.expect(buffer == .optional and buffer.optional.* == .pointer and buffer.optional.pointer.child.* == .primitive and std.mem.eql(u8, buffer.optional.pointer.child.primitive, "u16"));
}

test "Facts.literalType: a compared enum literal is of the other operand's type, type information's fields std.builtin.Type's" {
    const source =
        \\const std = @import("std");
        \\pub const Other = struct {
        \\    pub fn slice() void {}
        \\    pub fn neg() void {}
        \\};
        \\pub fn free(memory: anytype) void {
        \\    const info = @typeInfo(@TypeOf(memory)).pointer;
        \\    if (info.size != .slice) {}
        \\}
        \\pub fn parse(negative: bool) void {
        \\    const sign: enum { pos, neg } = if (negative) .neg else .pos;
        \\    if (sign == .neg) {}
        \\}
        \\pub const Sign = enum { pos, neg };
        \\pub fn maybe(opt: ?Sign) void {
        \\    if (opt == .neg) {}
        \\}
        \\pub const U = union(enum) { slice: u32, one };
        \\pub fn tagged(u: U) void {
        \\    if (u == .slice) {}
        \\}
    ;
    const lang =
        \\pub const Type = union(enum) {
        \\    pointer: Pointer,
        \\    pub const Pointer = struct {
        \\        size: Size,
        \\        child: type,
        \\        pub const Size = enum { one, many, slice, c };
        \\    };
        \\};
    ;
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "std/std.zig", .bytes = "pub const lang = @import(\"lang.zig\");\npub const builtin = lang;\n", .selected = false },
        .{ .name = "std/lang.zig", .bytes = lang, .selected = false },
    }, &.{
        .{ .from = 0, .spelling = "std", .target = 1 },
        .{ .from = 1, .spelling = "lang.zig", .target = 2 },
    }, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const t = (try facts.declaration(facts.member(facts.rootOf(project.sources[2].id), "Type").?)).container;
    const pointer = (try facts.declaration(facts.member(t, "Pointer").?)).container;
    const size = (try facts.declaration(facts.member(pointer, "Size").?)).container;
    // `size != .slice`: the tag of the information's `Size`, never another `slice`.
    try std.testing.expectEqual(Facts.Named{ .decl = facts.member(size, "slice").? }, try facts.literalDeclaration(file, spelledNode(tree, ".slice", 0).?, "slice"));
    // `sign == .neg`: the tag of `sign`'s own enum.
    const named = try facts.literalDeclaration(file, spelledNode(tree, ".neg", 1).?, "neg");
    try std.testing.expect(named == .decl and named.decl.file == file and !std.meta.eql(named.decl, facts.member((try facts.declaration(facts.member(facts.rootOf(file), "Other").?)).container, "neg").?));
    // `opt == .neg`, `opt` a `?Sign`: Zig coerces the literal to the optional, whose payload's
    // tag it names.
    const sign = (try facts.declaration(facts.member(facts.rootOf(file), "Sign").?)).container;
    try std.testing.expectEqual(Facts.Named{ .decl = facts.member(sign, "neg").? }, try facts.literalDeclaration(file, spelledNode(tree, ".neg", 2).?, "neg"));
    // `u == .slice`, `u` a tagged union: the union's tag, a field Zig gives no declaration
    // the same name.
    const u = (try facts.declaration(facts.member(facts.rootOf(file), "U").?)).container;
    try std.testing.expectEqual(Facts.Named{ .decl = facts.member(u, "slice").? }, try facts.literalDeclaration(file, spelledNode(tree, ".slice", 1).?, "slice"));
}

test "Facts.resolve: a builtin's value of the type its first argument names (an atomic load, a read-modify-write, @unionInit; a compare-and-exchange's optional)" {
    const source =
        \\const U = union { a: u32, b: bool };
        \\var x: u32 = 0;
        \\fn f() void {
        \\    const loaded = @atomicLoad(u32, &x, .acquire);
        \\    const old = @atomicRmw(u32, &x, .Add, 1, .monotonic);
        \\    const exchanged = @cmpxchgWeak(u32, &x, 0, 1, .acquire, .monotonic);
        \\    const strong = @cmpxchgStrong(u32, &x, 0, 1, .acquire, .monotonic);
        \\    const made = @unionInit(U, "a", 1);
        \\    _ = .{ loaded, old, exchanged, strong, made };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    for ([_][]const u8{ "loaded", "old" }) |name| {
        const value = try facts.resolve(file, spelledNode(tree, name, 0).?);
        try std.testing.expect(value == .primitive and std.mem.eql(u8, value.primitive, "u32"));
    }
    for ([_][]const u8{ "exchanged", "strong" }) |name| {
        const exchanged = try facts.resolve(file, spelledNode(tree, name, 0).?);
        try std.testing.expect(exchanged == .optional and exchanged.optional.* == .primitive and std.mem.eql(u8, exchanged.optional.primitive, "u32"));
    }
    const made = try facts.resolve(file, spelledNode(tree, "made", 0).?);
    try std.testing.expect(made == .instance and std.meta.eql(made.instance, (try facts.declaration(facts.member(facts.rootOf(file), "U").?)).container));
}

test "batch 2: an update's operation, error names and sets, a condition's truths, a value's leaves, a literal" {
    const source =
        \\const E = error{ Canceled, Timeout };
        \\const F = E || error{Other};
        \\const R = E!u8;
        \\const canceled = error.Canceled;
        \\fn g() R { return 0; }
        \\fn h() !u8 { return 0; }
        \\fn f(x: *u32, a: bool, b: bool, c: ?u8) u8 {
        \\    x.* +%= 1;
        \\    _ = @atomicRmw(u32, x, .Max, 2, .seq_cst);
        \\    _ = canceled;
        \\    _ = E.Timeout;
        \\    if (!(a and b) or x.* < 4) {}
        \\    if ((a) and (x.* == 2)) {}
        \\    return if (a) .{} else blk: { if (b) break :blk c orelse 3; break :blk @as(u8, 5); };
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    // `x.* +%= 1` wraps an add; `@atomicRmw(.., .Max, ..)` takes the larger.
    const update = (try accesses.storeInto(&facts, file, spelledNode(tree, "x.*", 0).?)).?;
    try std.testing.expectEqual(.add, update.operator.?.op.op);
    try std.testing.expectEqual(.wrapping, update.operator.?.op.overflow);
    // The values the `if` gives: `.{}`, `c`, `3`, `5`.
    const result = spelledNode(tree, "if (a) .{} else blk: { if (b) break :blk c orelse 3; break :blk @as(u8, 5); }", 0).?;
    const leaves = (try accesses.valuesOf(&facts, file, result)).leaves;
    try std.testing.expectEqual(@as(usize, 4), leaves.len);
    var spelled: [4][]const u8 = undefined;
    for (leaves, &spelled) |leaf, *out| out.* = tree.getNodeSource(leaf);
    for ([_][]const u8{ ".{}", "c", "3", "5" }) |want| {
        for (spelled) |got| {
            if (std.mem.eql(u8, got, want)) break;
        } else return error.TestUnexpectedResult;
    }
    try std.testing.expect((try facts.literalOf(file, spelledNode(tree, "5", 0).?)).? == .number);
    try std.testing.expectEqual(null, try facts.literalOf(file, spelledNode(tree, "c", 0).?));
}

test "accesses: asking a place's sites again keeps nothing more on the run's memory" {
    const source = shapes ++ "fn w(s: *S, t: S) void {\n    s.f = 1;\n    s.* = t;\n    const n = s.f;\n    _ = n;\n}\n";
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const model = &project.sources[0].model;
    const index = for (model.declarations, 0..) |d, i| {
        if (d.kind == .field and std.mem.eql(u8, d.name, "f")) break i;
    } else return error.TestUnexpectedResult;
    const place: accesses.Place = .{ .field = .{ .file = file, .index = @fromBackingInt(@intCast(index)) } };
    const in_file = [_]Project.FileId{file};
    // The first asking builds the file's index, kept for the run.
    var count: usize = 0;
    for (0..2) |_| {
        var writes = accesses.writes(&facts, place, &in_file);
        while (try writes.next()) |_| count += 1;
        var reads = accesses.reads(&facts, place, &in_file);
        while (try reads.next()) |_| count += 1;
    }
    try std.testing.expect(count > 0);
    const built = arena.queryCapacity();
    for (0..1000) |_| {
        var writes = accesses.writes(&facts, place, &in_file);
        while (try writes.next()) |_| {}
        var reads = accesses.reads(&facts, place, &in_file);
        while (try reads.next()) |_| {}
    }
    try std.testing.expectEqual(built, arena.queryCapacity());
}

test "shared 4: a view kept, chosen or taken of a part, a byte loop's copy, a capture's input, a loop's values" {
    const source =
        \\const Key = extern struct { bytes: [4]u8, tag: u8 };
        \\fn raw(p: anytype) *[5]u8 {
        \\    return @ptrCast(p);
        \\}
        \\fn part(p: *Key) *[4]u8 {
        \\    return &p.bytes;
        \\}
        \\fn held(p: *Key) []u8 {
        \\    var b: []u8 = raw(p);
        \\    _ = &b;
        \\    return b;
        \\}
        \\fn chosen(p: *Key, whole: bool) []u8 {
        \\    return if (whole) raw(p) else raw(p)[0..1];
        \\}
        \\fn other(p: *Key, q: *Key, first: bool) []u8 {
        \\    return if (first) raw(p) else raw(q);
        \\}
        \\fn copy(d: *Key, s: Key) void {
        \\    for (raw(d), raw(&s)) |*to, from| to.* = from;
        \\}
        \\fn values(xs: []const u8, c: bool) u8 {
        \\    const found = for (xs) |x| {
        \\        if (x == 0) break x;
        \\    } else 9;
        \\    const outer = while (c) {
        \\        while (c) {} else break 7;
        \\    } else 8;
        \\    const none = if (c) {};
        \\    _ = none;
        \\    return found + outer;
        \\}
        \\
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const root = facts.rootOf(file);
    // A view of a part of what the parameter points at, of a view a `var` keeps, of one an `if`
    // chooses between two of the same memory; none chosen between two parameters' memory.
    try std.testing.expectEqual(@as(?usize, 0), try facts.viewOf(facts.member(root, "part").?));
    try std.testing.expectEqual(@as(?usize, 0), try facts.viewOf(facts.member(root, "held").?));
    try std.testing.expectEqual(@as(?usize, 0), try facts.viewOf(facts.member(root, "chosen").?));
    try std.testing.expectEqual(@as(?usize, null), try facts.viewOf(facts.member(root, "other").?));
    // The byte loop copies `s`'s bytes into what `d` points at: the second capture is the second
    // input's.
    const copied = (try accesses.copyAt(&facts, file, spelledNode(tree, "to.* = from", 0).?)).?;
    try std.testing.expectEqualStrings("d", tree.getNodeSource(copied.into.node()));
    try std.testing.expect(copied.from == .place);
    try std.testing.expectEqualStrings("s", tree.getNodeSource(copied.from.node()));
    // A loop gives each `break` out of it and its `else`; a `break` in an inner loop's `else`
    // leaves the outer loop; an `if` with no `else` gives none.
    const loop = (try accesses.valuesOf(&facts, file, spelledNode(tree, "for (xs) |x| {\n        if (x == 0) break x;\n    } else 9", 0).?)).leaves;
    try std.testing.expectEqual(@as(usize, 2), loop.len);
    const outer = (try accesses.valuesOf(&facts, file, spelledNode(tree, "while (c) {\n        while (c) {} else break 7;\n    } else 8", 0).?)).leaves;
    try std.testing.expectEqual(@as(usize, 2), outer.len);
    try std.testing.expectEqual(@as(usize, 0), (try accesses.valuesOf(&facts, file, spelledNode(tree, "if (c) {}", 0).?)).leaves.len);
}

test "shared 4: a view handed to a function the program holds that writes through it" {
    const source =
        \\const Job = extern struct {
        \\    phase: u8 = 0,
        \\    fn raw(p: anytype) *[1]u8 {
        \\        return @ptrCast(p);
        \\    }
        \\    fn put(b: []u8, code: u8) void {
        \\        b[0] = code;
        \\    }
        \\    fn look(b: []u8) u8 {
        \\        return b[0];
        \\    }
        \\    pub fn force(j: *Job, code: u8) u8 {
        \\        put(raw(j), code);
        \\        return look(raw(j));
        \\    }
        \\};
        \\
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;
    const job = (try facts.declaration(facts.member(facts.rootOf(file), "Job").?)).container;
    const put = facts.member(job, "put").?;
    const look = facts.member(job, "look").?;
    try std.testing.expect(try accesses.writtenThrough(&facts, facts.parameterAt(put, 0).?));
    try std.testing.expect(!try accesses.writtenThrough(&facts, facts.parameterAt(look, 0).?));
    // `put(raw(j), code)` writes `phase` as bytes; `look(raw(j))` writes nothing.
    var at_put = false;
    var writes = accesses.writes(&facts, .{ .field = facts.member(job, "phase").? }, &.{file});
    while (try writes.next()) |site| {
        if (std.mem.eql(u8, tree.getNodeSource(site.node), "put(raw(j), code)")) at_put = true;
        try std.testing.expect(!std.mem.eql(u8, tree.getNodeSource(site.node), "look(raw(j))"));
    }
    try std.testing.expect(at_put);
}

test "accesses: a ZON file's literal writes the fields it initializes, whatever type the import gives it" {
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root.zig", .bytes = "const K = struct { n: u8 };\nconst k: K = @import(\"k.zon\");\npub fn f() u8 { return k.n; }\n" },
        .{ .name = "k.zon", .bytes = ".{ .n = 200 }\n", .kind = .zon },
    }, &.{.{ .from = 0, .spelling = "k.zon", .target = 1 }}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const root = project.sources[0].id;
    const zon = project.sources[1].id;
    const k = (try facts.declaration(facts.member(facts.rootOf(root), "K").?)).container;
    var init_site: ?accesses.Site = null;
    var writes = accesses.writes(&facts, .{ .field = facts.member(k, "n").? }, &.{ root, zon });
    while (try writes.next()) |site| if (site.file == zon) {
        init_site = site;
    };
    const site = init_site orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(accesses.Kind.init, site.kind);
    // The walk of the ZON file does not know the type the import gives the literal: a member
    // so named on a holder whose type is not known there, read by every query for such a field.
    try std.testing.expectEqual(accesses.Reach.named, site.reach);
    try std.testing.expectEqualStrings("200", project.sources[1].file.tree.getNodeSource(site.value.?));
}

test "consolidate: a member read's step, which language field it is, the program's @fields, a primitive integer's width" {
    const source =
        \\const S = struct { len: u32, ptr: u32, f: u8, g: u8 };
        \\fn f(s: *S, b: []const u8, a: [3]u8, x: anytype, comptime n: []const u8) usize {
        \\    @field(s, "f") = 1;
        \\    @field(s, n) = 2;
        \\    inline for (.{ "f", "g" }) |each| @field(s, each) = 3;
        \\    _ = @field(s, "g");
        \\    const listed = [_][]const u8{"g"};
        \\    inline for (listed) |one| _ = @field(s, one);
        \\    inline for (&listed) |one| _ = @field(s, one);
        \\    comptime var held = [_][]const u8{"g"};
        \\    held[0] = "g";
        \\    inline for (held) |one| _ = @field(s, one);
        \\    _ = b.ptr;
        \\    return s.len + b.len + a.len + x.len + s.ptr;
        \\}
    ;
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
    defer facts.deinit();
    const file = project.sources[0].id;
    const tree = &project.sources[0].file.tree;

    // Q1: `s.len` and `@field(s, "f")` are member reads on `s`, by name; `@field(s, n)`'s name
    // is computed; `s` itself is none.
    const dotted = (try accesses.memberRead(&facts, file, spelledNode(tree, "s.len", 0).?)).?;
    try std.testing.expectEqualStrings("len", dotted.name.?);
    try std.testing.expectEqualStrings("s", tree.getNodeSource(dotted.receiver.?));
    try std.testing.expect(dotted.crosses);
    const spelled = (try accesses.memberRead(&facts, file, spelledNode(tree, "@field(s, \"f\")", 0).?)).?;
    try std.testing.expectEqualStrings("f", spelled.name.?);
    try std.testing.expectEqualStrings("s", tree.getNodeSource(spelled.receiver.?));
    const computed = (try accesses.memberRead(&facts, file, spelledNode(tree, "@field(s, n)", 0).?)).?;
    try std.testing.expectEqual(null, computed.name);
    try std.testing.expectEqual(null, try accesses.memberRead(&facts, file, spelledNode(tree, "s", 0).?));

    // Q2: a slice's and an array's own `len`, a slice's `ptr`; a struct's fields so named are
    // none; a holder whose type does not resolve may be either.
    try std.testing.expect(try facts.languageField(file, spelledNode(tree, "b.len", 0).?) == .len);
    try std.testing.expect(try facts.languageField(file, spelledNode(tree, "a.len", 0).?) == .len);
    try std.testing.expect(try facts.languageField(file, spelledNode(tree, "b.ptr", 0).?) == .ptr);
    try std.testing.expect(try facts.languageField(file, spelledNode(tree, "s.len", 0).?) == .none);
    try std.testing.expect(try facts.languageField(file, spelledNode(tree, "s.ptr", 0).?) == .none);
    try std.testing.expect(try facts.languageField(file, spelledNode(tree, "x.len", 0).?) == .unknown);

    // Q3: `f` is named by its literal and by the inline loop's list, and may be the computed
    // ones (`n`, and a `var` list's, which is no `const`'s); `g` by its literal, the lists and
    // those; a name no `@field` may be gets the computed ones only.
    const for_f = try facts.fieldUses(arena.allocator(), "f");
    try std.testing.expectEqual(@as(usize, 4), for_f.len);
    var computed_seen: usize = 0;
    for (for_f) |use| computed_seen += @intFromBool(use.computed);
    try std.testing.expectEqual(@as(usize, 2), computed_seen);
    // A `const` list ranged over, by value or through `&`, names only its names.
    try std.testing.expectEqual(@as(usize, 6), (try facts.fieldUses(arena.allocator(), "g")).len);
    const other = try facts.fieldUses(arena.allocator(), "h");
    try std.testing.expectEqual(@as(usize, 2), other.len);
    for (other) |use| try std.testing.expect(use.computed);

    // Q2, per build: a holder that is a slice in one build and a struct with a `len` field in
    // another is unknown, never one of them.
    {
        const chosen =
            \\const S = struct { len: u32 };
            \\const Pick = switch (@import("builtin").os.tag) {
            \\    .windows => []const u8,
            \\    else => S,
            \\};
            \\fn f(p: Pick) usize {
            \\    return p.len;
            \\}
        ;
        var per_build = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = chosen }}, &.{}, .{});
        defer per_build.deinit();
        var per_build_facts: Facts = .{ .project = &per_build, .gpa = arena.allocator() };
        defer per_build_facts.deinit();
        const read = spelledNode(&per_build.sources[0].file.tree, "p.len", 0).?;
        try std.testing.expect(try per_build_facts.languageField(per_build.sources[0].id, read) == .unknown);
    }

    // Q4: Zig's and C's integers at a pointer width; comptime_int is a literal; others none.
    const Int = Facts.IntegerType;
    try std.testing.expectEqual(Int{ .int = .{ .bits = 16, .signed = true } }, Facts.integerType(.{ .primitive = "c_int" }, 16));
    try std.testing.expectEqual(Int{ .int = .{ .bits = 32, .signed = false } }, Facts.integerType(.{ .primitive = "usize" }, 32));
    try std.testing.expect(Facts.integerType(.{ .primitive = "ux" }, 64) == .unknown);
    try std.testing.expectEqual(Int{ .int = .{ .bits = 32, .signed = true } }, Facts.integerType(.{ .primitive = "c_int" }, 64));
    try std.testing.expectEqual(Int{ .int = .{ .bits = 16, .signed = false } }, Facts.integerType(.{ .primitive = "c_uint" }, 16));
    try std.testing.expectEqual(Int{ .int = .{ .bits = 32, .signed = true, .wide = 64 } }, Facts.integerType(.{ .primitive = "c_long" }, 64));
    try std.testing.expectEqual(Int{ .int = .{ .bits = 8, .signed = true, .either = true } }, Facts.integerType(.{ .primitive = "c_char" }, 32));
    try std.testing.expectEqual(Int{ .int = .{ .bits = 64, .signed = false } }, Facts.integerType(.{ .primitive = "usize" }, 64));
    try std.testing.expectEqual(Int{ .int = .{ .bits = 7, .signed = true } }, Facts.integerType(.{ .primitive = "i7" }, 64));
    try std.testing.expect(Facts.integerType(.{ .primitive = "comptime_int" }, 64) == .literal);
    try std.testing.expect(Facts.integerType(.{ .primitive = "c_longdouble" }, 64) == .unknown);
    try std.testing.expect(Facts.integerType(.{ .primitive = "bool" }, 64) == .unknown);
}
