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
    /// Each site found, as "line kind reach", with " part", " through", " deferred" as set.
    expected: []const []const u8,
};

const S = "const S = struct { f: u32 = 0, g: u32 = 0, a: [4]u8 = @splat(0) };\nconst T = struct { f: u32 = 0, g: u32 = 0 };\n";

const rows = [_]Row{
    .{ .name = "W1 x.f = v", .source = S ++ "fn w(s: *S) void {\n    s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W1 twin", .source = S ++ "fn w(s: *S) void {\n    s.g = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W1 x = v", .source = "fn w() void {\n    var x: u32 = 0;\n    x = 1;\n    var y: u32 = 0;\n    y = 2;\n}\n", .place = "x", .decl = true, .expected = &.{ "2 init exact", "3 set exact" } },
    .{ .name = "W2 op=", .source = S ++ "fn w(s: *S) void {\n    s.f += 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 update exact through" } },
    .{ .name = "W2 twin", .source = S ++ "fn w(s: *S) void {\n    s.g += 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W3 destructure", .source = S ++ "fn w(s: *S) void {\n    s.f, s.g = .{ 1, 2 };\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W3 twin", .source = S ++ "fn w(s: *S) void {\n    s.g, _ = .{ 1, 2 };\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W4 @field spelled", .source = S ++ "fn w(s: *S) void {\n    @field(s, \"f\") = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W4 twin", .source = S ++ "fn w(s: *S) void {\n    @field(s, \"g\") = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W4 @field computed", .source = S ++ "fn w(s: *S, comptime n: []const u8) void {\n    @field(s, n) = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set holder part through computed" } },
    .{ .name = "W4 computed twin", .source = S ++ "fn w(t: *T, comptime n: []const u8) void {\n    @field(t, n) = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W5 pointer capture", .source = S ++ "fn w(s: *S) void {\n    for (s.a) |*p| p.* = 0;\n}\n", .place = "a", .expected = &.{ "1 init exact", "4 address exact through" } },
    .{ .name = "W5 twin", .source = S ++ "fn w(s: *S) u8 {\n    var n: u8 = 0;\n    for (s.a) |p| n +%= p;\n    return n;\n}\n", .place = "a", .expected = &.{"1 init exact"} },
    .{ .name = "W5 written through", .source = S ++ "fn w(items: []S) void {\n    for (items) |*s| s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through" } },
    .{ .name = "W6 address", .source = S ++ "fn w(s: *S) void {\n    const p = &s.f;\n    p.* = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 address exact through" } },
    .{ .name = "W6 twin", .source = S ++ "fn w(s: *S) void {\n    const p = &s.g;\n    p.* = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W8 whole store", .source = S ++ "fn w(s: *S, t: S) void {\n    s.* = t;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set holder through" } },
    .{ .name = "W8 twin", .source = S ++ "fn w(s: *T, t: T) void {\n    s.* = t;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W8 holder by value", .source = S ++ "const O = struct { inner: S };\nfn w(o: *O, t: O) void {\n    o.* = t;\n}\n", .place = "f", .expected = &.{ "1 init exact", "5 set holder through" } },
    .{ .name = "W8 holder by pointer twin", .source = S ++ "const O = struct { inner: *S };\nfn w(o: *O, t: O) void {\n    o.* = t;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W9 memcpy", .source = S ++ "fn w(d: []S, s: []const S) void {\n    @memcpy(d, s);\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set holder through" } },
    .{ .name = "W9 twin", .source = S ++ "fn w(d: []T, s: []const T) void {\n    @memcpy(d, s);\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W10 cast", .source = S ++ "fn w(b: *[12]u8) *S {\n    return @ptrCast(@alignCast(b));\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered holder" } },
    .{ .name = "W10 twin", .source = S ++ "fn w(b: *[8]u8) *T {\n    return @ptrCast(@alignCast(b));\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W11 outside call", .source = S ++ "extern fn ext(p: *S) void;\nfn w(s: *S) void {\n    ext(s);\n}\n", .place = "f", .expected = &.{ "1 init exact", "5 covered holder" } },
    .{ .name = "W11 twin", .source = S ++ "extern fn ext(p: *T) void;\nfn w(t: *T) void {\n    ext(t);\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W12 element", .source = S ++ "fn w(v: S) void {\n    var arr: [2]S = undefined;\n    arr[0] = v;\n}\n", .place = "arr", .decl = true, .expected = &.{ "4 init exact", "5 set exact part" } },
    .{ .name = "W12 element's field", .source = S ++ "fn w(v: S) void {\n    var arr: [2]S = undefined;\n    arr[0] = v;\n}\n", .place = "f", .expected = &.{ "1 init exact", "5 set holder" } },
    .{ .name = "W13 defer", .source = S ++ "fn w(s: *S) void {\n    defer s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set exact through deferred" } },
    .{ .name = "W13 twin", .source = S ++ "fn w(s: *S) void {\n    defer s.g = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "W14 asm", .source = S ++ "fn w() void {\n    asm volatile (\"\");\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 covered unresolved" } },
    .{ .name = "W14 twin", .source = S ++ "fn w() void {}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "unresolved holder", .source = S ++ "fn w(s: anytype) void {\n    s.f = 1;\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 set named" } },
    .{ .name = "unresolved holder twin", .source = S ++ "fn w(s: anytype) void {\n    s.g = 1;\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "literal", .source = S ++ "fn w() S {\n    return .{ .f = 1 };\n}\n", .place = "f", .expected = &.{ "1 init exact", "4 init exact" } },
    .{ .name = "literal twin", .source = S ++ "fn w() S {\n    return .{ .g = 1 };\n}\n", .place = "f", .expected = &.{"1 init exact"} },
    .{ .name = "method receiver", .source = "const S = struct {\n    f: u32,\n    fn bump(self: *S) void {\n        self.f += 1;\n    }\n};\nfn w() void {\n    var s: S = .{ .f = 0 };\n    s.bump();\n}\n", .place = "s", .decl = true, .expected = &.{ "8 init exact", "9 address exact" } },
    .{ .name = "method receiver twin", .source = "const S = struct {\n    f: u32,\n    fn get(self: S) u32 {\n        return self.f;\n    }\n};\nfn w() u32 {\n    var s: S = .{ .f = 0 };\n    return s.get();\n}\n", .place = "s", .decl = true, .expected = &.{"8 init exact"} },
    .{ .name = "R1 name", .source = "fn w() u32 {\n    const x: u32 = 1;\n    const z: u32 = 2;\n    _ = z;\n    return x;\n}\n", .place = "x", .decl = true, .query = .reads, .expected = &.{"5 read exact"} },
    .{ .name = "R2 member", .source = S ++ "fn w(s: S) u32 {\n    return s.f;\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read exact"} },
    .{ .name = "R2 twin", .source = S ++ "fn w(s: S) u32 {\n    return s.g;\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R3 @field", .source = S ++ "fn w(s: S) u32 {\n    return @field(s, \"f\");\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read exact"} },
    .{ .name = "R3 twin", .source = S ++ "fn w(s: S) u32 {\n    return @field(s, \"g\");\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R4 capture", .source = S ++ "fn w(items: []const S, out: *S) void {\n    for (items) |it| out.* = it;\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read holder"} },
    .{ .name = "R4 twin", .source = S ++ "fn w(items: []const T, out: *T) void {\n    for (items) |it| out.* = it;\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R5 copy", .source = S ++ "fn w(p: *const S) S {\n    return p.*;\n}\n", .place = "f", .query = .reads, .expected = &.{"4 read holder"} },
    .{ .name = "R5 twin", .source = S ++ "fn w(p: *const T) T {\n    return p.*;\n}\n", .place = "f", .query = .reads, .expected = &.{} },
    .{ .name = "R6 address", .source = "fn w() *const u32 {\n    const x: u32 = 1;\n    return &x;\n}\n", .place = "x", .decl = true, .expected = &.{ "2 init exact", "3 address exact" } },
};

fn found(a: std.mem.Allocator, project: *const Project, site: accesses.Site) ![]const u8 {
    const tree = &project.at(site.file).file.tree;
    const line = tree.tokenLocation(0, tree.firstToken(site.node)).line + 1;
    return std.fmt.allocPrint(a, "{d} {t} {t}{s}{s}{s}{s}", .{ line, site.kind, site.reach, if (site.part) " part" else "", if (site.through) " through" else "", if (site.deferred) " deferred" else "", if (site.computed) " computed" else "" });
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
            .writes => try accesses.writes(&facts, place, &.{file}),
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
