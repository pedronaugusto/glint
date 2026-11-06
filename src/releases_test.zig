//! The construct matrix of `releases.released`: each way a function may release an owner its
//! parameter holds, read as released on every exit only where it is, this instance; unknown
//! otherwise.
const std = @import("std");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");
const releases = @import("releases.zig");

/// A release by the type alone, for these rows: a function named `close`.
fn closes(facts: *Facts, callee: Facts.Decl, _: Facts.Value) releases.Error!bool {
    const record = facts.project.at(callee.file).model.declarations[@backingInt(callee.index)];
    return std.mem.eql(u8, record.name, "close");
}
const base: releases.Base = .{ .notion = .std_handle, .isRelease = closes };

const handle = "const Handle = struct {\n    fd: u8,\n    fn close(h: *Handle) void {\n        _ = h;\n    }\n};\nfn g() !void {}\n";
const plain = handle ++ "const R = struct { h: Handle, n: u8 };\n";
const optional = handle ++ "const R = struct { h: ?Handle, n: u8 };\n";

const Row = struct {
    name: []const u8,
    source: []const u8,
    /// The function read, and the parameter holding the owner at field `h` of what it points at.
    function: []const u8 = "deinit",
    parameter: usize = 0,
    expected: std.meta.Tag(releases.Released),
};

const rows = [_]Row{
    .{ .name = "a release of the field", .source = plain ++ "fn deinit(r: *R) void {\n    r.h.close();\n}\n", .expected = .every_exit },
    .{ .name = "a release on one branch only", .source = plain ++ "fn deinit(r: *R, c: bool) void {\n    if (c) r.h.close();\n}\n", .expected = .unknown },
    .{ .name = "another instance's release", .source = plain ++ "fn deinit(r: *R, other: *R) void {\n    _ = r;\n    other.h.close();\n}\n", .expected = .unknown },
    .{ .name = "a release through two helpers", .source = plain ++ "fn drop(r: *R) void {\n    r.h.close();\n}\nfn all(r: *R) void {\n    drop(r);\n}\nfn deinit(r: *R) void {\n    all(r);\n}\n", .expected = .every_exit },
    .{ .name = "a deferred release", .source = plain ++ "fn deinit(r: *R) void {\n    defer r.h.close();\n    r.n = 0;\n}\n", .expected = .every_exit },
    .{ .name = "an errdefer's release only", .source = plain ++ "fn deinit(r: *R) !void {\n    errdefer r.h.close();\n    try g();\n}\n", .expected = .unknown },
    .{ .name = "a try before the release", .source = plain ++ "fn deinit(r: *R) !void {\n    try g();\n    r.h.close();\n}\n", .expected = .unknown },
    .{ .name = "a try after a deferred release", .source = plain ++ "fn deinit(r: *R) !void {\n    defer r.h.close();\n    try g();\n}\n", .expected = .every_exit },
    .{ .name = "the owner's own optional", .source = optional ++ "fn deinit(r: *R) void {\n    if (r.h) |*h| h.close();\n}\n", .expected = .every_exit },
    .{ .name = "the owner's own optional, cleared after", .source = optional ++ "fn deinit(r: *R) void {\n    if (r.h) |*h| {\n        h.close();\n        r.h = null;\n    }\n}\n", .expected = .every_exit },
    .{ .name = "the optional's payload copied", .source = optional ++ "fn deinit(r: *R) void {\n    if (r.h) |h| {\n        var c = h;\n        c.close();\n    }\n}\n", .expected = .unknown },
    .{ .name = "a release in a loop", .source = plain ++ "fn deinit(r: *R, n: u8) void {\n    var i: u8 = 0;\n    while (i < n) : (i += 1) r.h.close();\n}\n", .expected = .unknown },
    .{ .name = "a helper given it overwrites it first", .source = plain ++ "fn reset(r: *R) void {\n    r.h = .{ .fd = 0 };\n}\nfn deinit(r: *R) void {\n    reset(r);\n    r.h.close();\n}\n", .expected = .unknown },
    .{ .name = "a store over it first", .source = plain ++ "fn deinit(r: *R, x: Handle) void {\n    r.h = x;\n    r.h.close();\n}\n", .expected = .unknown },
    .{ .name = "an early return", .source = plain ++ "fn deinit(r: *R, c: bool) void {\n    if (c) return;\n    r.h.close();\n}\n", .expected = .unknown },
    .{ .name = "a field beside it written first", .source = plain ++ "fn deinit(r: *R) void {\n    r.n = 1;\n    r.h.close();\n}\n", .expected = .every_exit },
    .{ .name = "a parameter by value", .source = plain ++ "fn deinit(r: R) void {\n    var c = r;\n    c.h.close();\n}\n", .expected = .unknown },
    .{ .name = "no release", .source = plain ++ "fn deinit(r: *R) void {\n    r.n = 0;\n}\n", .expected = .untouched },
    .{ .name = "a field beside it read, through a helper", .source = plain ++ "fn count(r: *R) u8 {\n    return r.n;\n}\nfn size(r: *R) u8 {\n    return count(r);\n}\n", .function = "size", .expected = .untouched },
    .{ .name = "handed to a helper that may release it", .source = plain ++ "fn maybe(r: *R, c: bool) void {\n    if (c) r.h.close();\n}\nfn deinit(r: *R) void {\n    maybe(r, true);\n}\n", .expected = .unknown },
    .{ .name = "a recursive release", .source = plain ++ "fn deinit(r: *R) void {\n    deinit(r);\n}\n", .expected = .unknown },
};

fn fieldOf(facts: *Facts, file: Project.FileId, container: []const u8, field: []const u8) !Facts.Decl {
    const model = &facts.project.at(file).model;
    for (model.declarations, 0..) |d, i| if (d.kind == .variable and std.mem.eql(u8, d.name, container)) {
        const value = try facts.declaration(.{ .file = file, .index = @fromBackingInt(@intCast(i)) });
        const found = switch (value) {
            .container, .instance => |c| c,
            else => return error.TestUnexpectedResult,
        };
        return facts.member(found, field) orelse error.TestUnexpectedResult;
    };
    return error.TestUnexpectedResult;
}

fn functionOf(facts: *Facts, file: Project.FileId, name: []const u8) !Facts.Decl {
    const model = &facts.project.at(file).model;
    for (model.declarations, 0..) |d, i| if (d.kind == .function and std.mem.eql(u8, d.name, name)) return .{ .file = file, .index = @fromBackingInt(@intCast(i)) };
    return error.TestUnexpectedResult;
}

test "releases: each construct is released on every exit only where it is, this instance" {
    var failed = false;
    for (rows) |row| {
        var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = row.source }}, &.{}, .{});
        defer project.deinit();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var facts: Facts = .{ .project = &project, .gpa = arena.allocator() };
        defer facts.deinit();
        const file = project.sources[0].id;
        const field = try fieldOf(&facts, file, "R", "h");
        const got = try releases.released(&facts, try functionOf(&facts, file, row.function), .{ .parameter = row.parameter, .path = &.{field} }, base);
        if (got == row.expected) continue;
        failed = true;
        std.debug.print("{s}: expected {t}, found {any}\n", .{ row.name, row.expected, got });
    }
    try std.testing.expect(!failed);
}
