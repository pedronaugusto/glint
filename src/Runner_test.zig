//! Compatibility contracts use complete contrasting source inputs and stable IDs.
const std = @import("std");
const glint = @import("glint.zig");

fn check(rule: glint.Rule, source: []const u8, expected: usize) !void {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture", .stem = "Fixture", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(rule, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(expected, report.diagnostics.len);
    try std.testing.expect(report.complete);
}

test "compatibility Z012 enclosing-container visibility is declaration based" {
    try check(.Z012, "const Outer = struct { pub const Public = struct {}; const Private = struct {}; pub fn good(v: Public) Public { return v; } pub fn bad(v: Private) Private { return v; } };", 2);
}

test "compatibility Z015 merged named error sets preserve public provenance" {
    try check(.Z015, "pub const A = error{A}; pub const B = error{B}; pub const Combined = A || B; pub fn good() Combined!void {}", 0);
    try check(.Z015, "const Private = error{Bad}; pub fn bad() Private!void {}", 1);
}

test "compatibility Z023 only the actual nested container is a receiver" {
    try check(.Z023, "const Outer = struct { const Inner = struct { pub fn good(self: *Inner, comptime T: type) void { _ = self; _ = T; } }; };", 0);
    try check(.Z023, "const Other = struct {}; const Outer = struct { pub fn bad(other: *Other, comptime T: type) void { _ = other; _ = T; } };", 1);
}

test "compatibility Z011 finds deprecated calls at every expression position" {
    const source =
        \\const d = @import("dep");
        \\pub fn run(flag: bool) u8 {
        \\    const x = .{ .value = d.old() };
        \\    defer _ = d.old();
        \\    const y = if (flag) d.old() else d.modern(d.old());
        \\    const z = switch (y) { 0 => d.old(), else => x.value };
        \\    return d.modern(d.old()) + z;
        \\}
        \\comptime { _ = d.old(); }
    ;
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = source },
        .{ .name = "dep", .selected = false, .bytes = "/// Deprecated: use modern.\npub fn old() u8 { return 1; } pub fn modern(x: u8) u8 { return x; }" },
    }, &.{.{ .from = @fromBackingInt(0), .spelling = "dep", .target = @fromBackingInt(1) }}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z011, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 7), report.diagnostics.len);
    try std.testing.expect(report.complete);
}

test "compatibility declaration and naming contrasts" {
    const Case = struct { rule: glint.Rule, bad: []const u8, good: []const u8 };
    for ([_]Case{
        .{ .rule = .Z001, .bad = "pub fn Bad_name() void {}", .good = "pub fn goodName() void {}" },
        .{ .rule = .Z002, .bad = "const _unused = 1;", .good = "const __internal = 1;" },
        .{ .rule = .Z004, .bad = "const S = struct {}; const s = S{};", .good = "const S = struct {}; const s: S = .{};" },
        .{ .rule = .Z005, .bad = "pub fn factory() type { return struct {}; }", .good = "pub fn Factory() type { return struct {}; }" },
        .{ .rule = .Z006, .bad = "const badName = 1;", .good = "const good_name = 1;" },
        .{ .rule = .Z007, .bad = "const a = @import(\"dep\"); const b = @import(\"dep\");", .good = "const a = @import(\"a\"); const b = @import(\"b\");" },
        .{ .rule = .Z010, .bad = "const S = struct {}; pub fn f() S { return S{}; }", .good = "const S = struct {}; pub fn f() S { return .{}; }" },
        .{ .rule = .Z014, .bad = "const errors = error{Bad};", .good = "const Errors = error{Bad};" },
        .{ .rule = .Z017, .bad = "pub fn f() !u8 { return try g(); } fn g() !u8 { return 1; }", .good = "pub fn f() !u8 { return g(); } fn g() !u8 { return 1; }" },
        .{ .rule = .Z018, .bad = "const x: u8 = @as(u8, 1);", .good = "const x: u8 = 1;" },
        .{ .rule = .Z019, .bad = "const S = struct { const Self = @This(); };", .good = "const S = struct { const Self = S; };" },
        .{ .rule = .Z020, .bad = "pub fn f(s: *@This()) void { _ = s; }", .good = "const Self = @This(); pub fn f(s: *Self) void { _ = s; }" },
        .{ .rule = .Z021, .bad = "value: u8, const Wrong = @This();", .good = "value: u8, const Fixture = @This();" },
        .{ .rule = .Z022, .bad = "pub fn Factory() type { return struct { const Wrong = @This(); }; }", .good = "pub fn Factory() type { return struct { const Self = @This(); }; }" },
        .{ .rule = .Z025, .bad = "pub fn f() !void { g() catch |err| return err; } fn g() !void {}", .good = "pub fn f() !void { try g(); } fn g() !void {}" },
        .{ .rule = .Z026, .bad = "pub fn f() void { g() catch {}; } fn g() !void {}", .good = "pub fn f() void { defer g() catch {}; } fn g() !void {}" },
        .{ .rule = .Z028, .bad = "pub fn f() void { const d = @import(\"dep\"); _ = d; }", .good = "const d = @import(\"dep\"); pub fn f() void { _ = d; }" },
        .{ .rule = .Z031, .bad = "pub fn _private() void {}", .good = "pub fn __internal() void {}" },
        .{ .rule = .Z032, .bad = "pub fn readXML() void {}", .good = "pub fn readXml() void {}" },
        .{ .rule = .Z033, .bad = "const ValueManager = struct {};", .good = "const Record = struct {};" },
    }) |case| {
        try check(case.rule, case.bad, 1);
        try check(case.rule, case.good, 0);
    }
}

test "compatibility byte line length counts CRLF content and file-struct stem" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "opaque", .stem = "bad_name", .bytes = "value: u8,\r\n" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z024, true);
    config.set(.Z009, true);
    config.max_line_length = 10;
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len);
    try std.testing.expectEqual(glint.Rule.Z009, report.diagnostics[0].rule);
    try std.testing.expect(report.complete);
}
