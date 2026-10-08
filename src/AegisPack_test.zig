const std = @import("std");
const glint = @import("glint");
const P = glint.Project;
const pack = glint.AegisPack;
fn fixture(bytes: []const u8) !P {
    return P.init(std.testing.allocator, &.{
        .{ .name = "consumer", .bytes = bytes },
        .{ .name = "Secret.zig", .bytes = @embedFile("aegis-secret"), .selected = false },
        .{ .name = "Guarded.zig", .bytes = @embedFile("aegis-guarded"), .selected = false },
        .{ .name = "SecretBytes.zig", .bytes = @embedFile("aegis-bytes"), .selected = false },
        .{ .name = "int.zig", .bytes = @embedFile("aegis-int"), .selected = false },
        .{ .name = "scalar.zig", .bytes = @embedFile("aegis-scalar"), .selected = false },
    }, &.{
        .{ .from = P.FileId.fromRaw(0), .spelling = "secret", .target = P.FileId.fromRaw(1) },
        .{ .from = P.FileId.fromRaw(0), .spelling = "guarded", .target = P.FileId.fromRaw(2) },
        .{ .from = P.FileId.fromRaw(0), .spelling = "bytes", .target = P.FileId.fromRaw(3) },
        .{ .from = P.FileId.fromRaw(0), .spelling = "ints", .target = P.FileId.fromRaw(4) },
        .{ .from = P.FileId.fromRaw(4), .spelling = "scalar.zig", .target = P.FileId.fromRaw(5) },
    }, .{});
}
const config: glint.Config = .{ .enabled = @splat(false), .selections = &.{
    .{ .rule = pack.access, .level = .report },
    .{ .rule = pack.copies, .level = .report },
    .{ .rule = pack.cleanup, .level = .report },
    .{ .rule = pack.scalar, .level = .report },
    .{ .rule = pack.capacity, .level = .report },
} };
fn count(report: glint.Report, id: glint.Rule) usize {
    var total: usize = 0;
    for (report.diagnostics) |d| if (d.rule == id) {
        total += 1;
    };
    return total;
}
test "aegis pack pinned identity access copies scalar and capacity reports" {
    var project = try fixture(
        \\const Secret = @import("secret").Secret;
        \\const Guarded = @import("guarded").Guarded;
        \\const Bytes = @import("bytes");
        \\const Checked = @import("ints").Checked;
        \\pub fn f(gpa: anytype, allocation: []u8, n: usize) !void {
        \\    var s = Secret(u32).init(9);
        \\    defer s.deinit();
        \\    _ = s.material;
        \\    const copy = s;
        \\    _ = copy;
        \\    var g = Guarded(u32).init(0);
        \\    _ = g.data;
        \\    var held = g.acquire();
        \\    defer held.deinit();
        \\    _ = held.owner;
        \\    const a = Checked(u32).init(1);
        \\    _ = a.raw() + 2;
        \\    _ = @as(u8, @intCast(a.raw()));
        \\    var b = try Bytes.adopt(gpa, allocation[0..n], n);
        \\    defer b.deinit();
        \\    _ = b.allocation;
        \\}
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 4), count(report, pack.access)); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.copies)); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 2), count(report, pack.scalar)); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.capacity)); // safe: fixture counts are representable.
    for (report.diagnostics) |d| try std.testing.expectEqual(glint.Config.Level.report, d.level);
}
test "aegis pack local end without cleanup contrasts deferred owner" {
    var project = try fixture(
        \\const Secret = @import("secret").Secret;
        \\pub fn missing() void { var s = Secret(u32).init(1); _ = &s; }
        \\pub fn safe() void { var s = Secret(u32).init(1); defer s.deinit(); }
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.cleanup)); // safe: fixture count is representable.
}
test "aegis pack rejects gates and uncategorized exceptions" {
    var project = try fixture("const S = @import(\"secret\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }");
    defer project.deinit();
    try std.testing.expectError(error.InvalidSelection, glint.runConfigured(std.testing.allocator, &project, .{ .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules }));
    var invalid = try fixture("const S = @import(\"secret\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; } // glint-ignore: A001 -- test\n");
    defer invalid.deinit();
    try std.testing.expectError(error.MalformedSuppression, glint.runConfigured(std.testing.allocator, &invalid, config, .{ .project_rules = &pack.rules }));
    var valid = try fixture("const S = @import(\"secret\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; } // glint-ignore: A001 -- safe-type-internals: fixture; inspect representation to test erasure\n");
    defer valid.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &valid, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: fixture count is representable.
}
test "aegis pack unrelated spelling and explicit exposure do not allege backing misuse" {
    var project = try fixture(
        \\const Secret = struct { material: u32, pub fn init(n: u32) @This() { return .{ .material = n }; } };
        \\pub fn f() void { const s = Secret.init(1); _ = s.material; const copy = s; _ = copy; }
        \\const A = @import("secret").Secret;
        \\const Template = A(u32);
        \\const Alias = Template;
        \\pub const PublicAlias = Alias;
        \\pub fn borrow(s: *A(u32)) *const u32 { return s.expose(); }
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), count(report, pack.access)); // safe: fixture count is representable.
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.copies)); // safe: fixture count is representable.
}
