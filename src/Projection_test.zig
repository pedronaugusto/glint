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

test "morning builtin is_test marks only the test branch without import mappings" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const b = @import(\"builtin\"); pub fn f() void { if (b.is_test) { _ = @import(\"test.zig\"); } else { _ = @import(\"prod.zig\"); } }" }}, &.{}, .{});
    defer project.deinit();
    var projection = try glint.Projection.init(std.testing.allocator, &project, 1000);
    defer projection.deinit();
    for (projection.imports) |imp| if (imp.spelling) |name| {
        if (std.mem.eql(u8, name, "test.zig")) try std.testing.expectEqual(glint.Projection.Context.@"test", imp.context);
        if (std.mem.eql(u8, name, "prod.zig")) try std.testing.expect(imp.context != .@"test");
    };
}

test "morning semantic reflection named tests and declaration literals supply identities" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "fn target() void {} test target {} const Self = @This(); pub fn f() void { _ = .target; _ = @field(Self, \"target\"); _ = @hasDecl(Self, \"target\"); }" }}, &.{}, .{});
    defer project.deinit();
    var projection = try glint.Projection.init(std.testing.allocator, &project, 1000);
    defer projection.deinit();
    var matches: usize = 0;
    for (projection.references) |ref| if (ref.definition) |d| {
        const h = try project.handle(d.file);
        if (std.mem.eql(u8, (try project.declarations(h))[d.index].name, "target")) matches += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), matches); // safe: named test and two reflection strings; untyped literals remain undecided.
}

test "morning syntax model without lowering retains imports without mappings" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "pub const dep = @import(\"unmapped\");" }}, &.{}, .{ .lowering = false });
    defer project.deinit();
    const h = try project.handle(glint.Project.FileId.fromRaw(0));
    try std.testing.expect((try project.lowered(h)) == null);
    try std.testing.expectEqual(.not_requested, try project.loweredCoverage(h));
    try std.testing.expectEqual(@as(usize, 1), (try project.declarations(h)).len); // safe: one declaration.
}

test "morning grouped negated builtin conditions classify the else arm and preserve lookalikes" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const b = @import(\"builtin\"); pub fn f() void { if (!(b.is_test)) { _ = @import(\"prod.zig\"); } else { _ = @import(\"test.zig\"); } }" }}, &.{}, .{});
    defer project.deinit();
    var projection = try glint.Projection.init(std.testing.allocator, &project, 1000);
    defer projection.deinit();
    for (projection.imports) |imp| if (imp.spelling) |name| {
        if (std.mem.eql(u8, name, "test.zig")) try std.testing.expectEqual(glint.Projection.Context.@"test", imp.context);
        if (std.mem.eql(u8, name, "prod.zig")) try std.testing.expect(imp.context != .@"test");
    };
}
