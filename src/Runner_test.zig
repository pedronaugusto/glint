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
