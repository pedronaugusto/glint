const std = @import("std");
const glint = @import("glint");
test "G2 projection preserves escaped imports nested test contexts reexports and lazy sources" {
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "pub const exposed = @import(\"d\\x65p\");\ntest \"nested\" { const only = @import(\"testdep\"); _ = only; }\nfn lazy() void { const still = @import(\"dep\"); _ = still; }\ncomptime { _ = @import(\"dep\"); }" },
        .{ .name = "dependency", .bytes = "pub const value = 1;", .selected = false },
    }, &.{ .{ .from = glint.Project.FileId.fromRaw(0), .target = glint.Project.FileId.fromRaw(1), .spelling = "dep" }, .{ .from = glint.Project.FileId.fromRaw(0), .target = glint.Project.FileId.fromRaw(1), .spelling = "testdep" } }, .{});
    defer project.deinit();
    var projection = try glint.Projection.init(std.testing.allocator, &project, 1000);
    defer projection.deinit();
    try std.testing.expect(projection.complete);
    try std.testing.expectEqual(@as(usize, 4), projection.imports.len); // safe: four literal imports in fixture.
    var tests: usize = 0;
    var comptimes: usize = 0;
    for (projection.imports) |edge| {
        try std.testing.expect(edge.target.?.eql(glint.Project.FileId.fromRaw(1)));
        if (edge.context == .@"test") tests += 1;
        if (edge.context == .@"comptime") comptimes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), tests); // safe: one nested test import.
    try std.testing.expectEqual(@as(usize, 1), comptimes); // safe: one comptime import.
}
test "G2 projection carries actual ZIR method-call identity and missing-map uncertainty" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const S = struct { fn read(self: S) u8 { _ = self; return 1; } }; pub fn run(s: S) u8 { return s.read(); }" }}, &.{}, .{});
    defer project.deinit();
    var projection = try glint.Projection.init(std.testing.allocator, &project, 1000);
    defer projection.deinit();
    try std.testing.expectEqual(@as(usize, 1), projection.calls.len); // safe: single supported method call.
    try std.testing.expect(projection.calls[0].instruction != null);
    try std.testing.expect(projection.calls[0].definition != null);
    try std.testing.expect(projection.calls[0].unknown == null);
    var unknown = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "pub const dep = @import(\"unmapped\");" }}, &.{}, .{});
    defer unknown.deinit();
    var missing = try glint.Projection.init(std.testing.allocator, &unknown, 1000);
    defer missing.deinit();
    try std.testing.expect(!missing.complete);
    try std.testing.expectEqual(.missing_mapping, missing.imports[0].unknown.?);
}

test "G2 projection context validates caller source and token identities" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "source", .bytes = "pub const value = 1;" }}, &.{}, .{});
    defer project.deinit();
    try std.testing.expectError(error.InvalidHandle, glint.Projection.context(&project, glint.Project.FileId.fromRaw(1), 0));
    try std.testing.expectError(error.InvalidHandle, glint.Projection.context(&project, glint.Project.FileId.fromRaw(0), 1000));
    try std.testing.expectEqual(.production, try glint.Projection.context(&project, glint.Project.FileId.fromRaw(0), 1));
}
