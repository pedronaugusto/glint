//! Public contracts: allocation failures, arbitrary parser input and rendering.
const std = @import("std");
const glint = @import("glint");
const shakedown = @import("shakedown");

test "contract allocation failures release project and report owners" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var project = try glint.Project.init(a, &.{.{ .name = "fixture", .bytes = "const d = @import(\"dep\"); pub fn f() void {}" }}, &.{}, .{});
            defer project.deinit();
            var report = try glint.run(a, &project, glint.Config.reviewed());
            defer report.deinit();
            var output: std.Io.Writer.Allocating = .init(a);
            defer output.deinit();
            report.write(&output.writer, &project, .json) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => return err,
            }; // Allocating has no failure other than allocation.
        }
    };
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Case.run, .{});
}

test "contract seeded arbitrary bytes parse with bounded public ownership" {
    const Property = struct {
        fn run(_: void, case: *shakedown.Case) !void {
            var bytes: [128]u8 = undefined;
            const count = shakedown.gen.intRange(case.source, usize, 0, bytes.len);
            for (bytes[0..count]) |*byte| byte.* = shakedown.gen.int(case.source, u8);
            var project = try glint.Project.init(case.gpa, &.{.{ .name = "arbitrary", .bytes = bytes[0..count] }}, &.{}, .{});
            defer project.deinit();
            var report = try glint.run(case.gpa, &project, .{});
            defer report.deinit();
            for (report.diagnostics) |diagnostic| {
                try std.testing.expect(diagnostic.span.start <= count);
                try std.testing.expect(diagnostic.span.end <= count);
            }
        }
    };
    try shakedown.check(std.testing.allocator, {}, Property.run, .{ .cases = 64 });
}

test "contract JSON and SARIF preserve stable IDs and reasoned suppressions" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture", .bytes = "const one = @import(\"one\");\n// glint-ignore: Z013 -- test-only retained declaration\nconst two = @import(\"two\");" }}, &.{}, .{});
    defer project.deinit();
    var report = try glint.run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: explicit compile-time type selection; the value is representable in that type.
    for ([_]glint.Report.Format{ .json, .sarif }) |format| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try report.write(&output.writer, &project, format);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        try std.testing.expect(std.mem.find(u8, output.written(), "Z013") != null);
    }
}

test "contract a report cannot silently render against another project snapshot" {
    var first = try glint.Project.init(std.testing.allocator, &.{.{ .name = "first", .bytes = "const d = @import(\"dep\");" }}, &.{}, .{});
    defer first.deinit();
    var other = try glint.Project.init(std.testing.allocator, &.{.{ .name = "other", .bytes = "pub const x = 1;" }}, &.{}, .{});
    defer other.deinit();
    var report = try glint.run(std.testing.allocator, &first, .{});
    defer report.deinit();
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expectError(error.InvalidProject, report.write(&output.writer, &other, .json));
}

test "contract public lowered references disclose partial std ZIR coverage" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture", .bytes = "const x = 1; pub fn f() u32 { return x; }" }}, &.{}, .{});
    defer project.deinit();
    const handle = try project.handle(glint.Project.FileId.fromRaw(0)); // safe: source zero exists in this fixture.
    try std.testing.expectEqual(.partial, try project.loweredCoverage(handle));
    try std.testing.expect((try project.loweredReferences(handle)).len != 0);
}

test "contract deprecation diagnostic carries its resolved declaration span" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture label", .bytes = "/// Deprecated: use fresh.\nfn old() void {} pub fn run() void { old(); }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z011, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: expected single fixture diagnostic fits usize.
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics[0].related.len); // safe: expected single declaration span fits usize.
    try std.testing.expectEqual(@as(u32, 30), report.diagnostics[0].related[0].start); // safe: the declaration name begins at byte 30 of the fixed fixture.
    for ([_]glint.Report.Format{ .json, .sarif }) |format| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try report.write(&output.writer, &project, format);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
        defer parsed.deinit();
        if (format == .json) {
            const related = parsed.value.object.get("diagnostics").?.array.items[0].object.get("related").?.array.items[0];
            try std.testing.expectEqualStrings("fixture label", related.object.get("source").?.string);
        } else {
            const diagnostic = parsed.value.object.get("runs").?.array.items[0].object.get("results").?.array.items[0];
            const location = diagnostic.object.get("relatedLocations").?.array.items[0].object.get("physicalLocation").?;
            try std.testing.expectEqualStrings("fixture%20label", location.object.get("artifactLocation").?.object.get("uri").?.string);
            try std.testing.expectEqual(@as(i64, 30), location.object.get("region").?.object.get("byteOffset").?.integer); // safe: byte 30 of the fixed fixture fits i64.
        }
    }
}

test "contract G2 allocation failures release projection and dead-private owners" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var project = try glint.Project.init(a, &.{.{ .name = "model", .bytes = "fn unused() void {} pub fn live() void {}" }}, &.{}, .{});
            defer project.deinit();
            var projection = try glint.Projection.init(a, &project, 1000);
            defer projection.deinit();
            var config = glint.Config.none();
            config.set(.D001, true);
            var report = try glint.run(a, &project, config);
            defer report.deinit();
            try std.testing.expect(report.complete);
            try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: known private unused fixture function.
        }
    };
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Case.run, .{});
}

test "contract invalid lowering never indexes partial ZIR declaration payloads" {
    var invalid = try glint.Project.init(std.testing.allocator, &.{.{ .name = "invalid", .bytes = "pub fn make() Unknown { return .{}; }" }}, &.{}, .{});
    defer invalid.deinit();
    try std.testing.expectEqual(.invalid_lowering, invalid.files[0].status);
    try std.testing.expectEqual(@as(usize, 0), invalid.models[0].zir_declarations.len); // safe: rejected lowering has no admitted declaration payloads.
    var report = try glint.run(std.testing.allocator, &invalid, .{});
    defer report.deinit();
    try std.testing.expect(!report.complete);
    var valid = try glint.Project.init(std.testing.allocator, &.{.{ .name = "valid", .bytes = "pub fn make() u8 { return 1; }" }}, &.{}, .{});
    defer valid.deinit();
    try std.testing.expect(valid.models[0].zir_declarations.len != 0);
}
