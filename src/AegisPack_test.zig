const std = @import("std");
const glint = @import("glint");
const P = glint.Project;
const pack = glint.AegisPack;
const aegis_sources = @import("aegis_sources");
fn fixture(bytes: []const u8) !P {
    return aegis_sources.project(std.testing.allocator, bytes);
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
test "aegis pack access copies scalar and capacity reports" {
    var project = try fixture(
        \\const Secret = @import("aegis").Secret;
        \\const Guarded = @import("aegis").Guarded;
        \\const Bytes = @import("aegis").SecretBytes;
        \\const Checked = @import("aegis").int.Checked;
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
        \\const Secret = @import("aegis").Secret;
        \\pub fn missing() void { var s = Secret(u32).init(1); _ = &s; }
        \\pub fn safe() void { var s = Secret(u32).init(1); defer s.deinit(); }
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.cleanup)); // safe: fixture count is representable.
}
test "aegis pack accepts adopted gates and rejects uncategorized exceptions" {
    var project = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }");
    defer project.deinit();
    var gated = try glint.runConfigured(std.testing.allocator, &project, .{ .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer gated.deinit();
    try std.testing.expect(gated.complete);
    try std.testing.expectEqual(glint.Config.Level.gate, gated.diagnostics[0].level);
    var invalid = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; } // glint-ignore: A001 -- test\n");
    defer invalid.deinit();
    try std.testing.expectError(error.MalformedSuppression, glint.runConfigured(std.testing.allocator, &invalid, config, .{ .project_rules = &pack.rules }));
    var valid = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; } // glint-ignore: A001 -- safe-type-internals: fixture; inspect representation to test erasure\n");
    defer valid.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &valid, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: fixture count is representable.
}
test "aegis pack unrelated spelling and explicit exposure do not allege backing misuse" {
    var project = try fixture(
        \\const Secret = struct { material: u32, pub fn init(n: u32) @This() { return .{ .material = n }; } };
        \\pub fn f() void { const s = Secret.init(1); _ = s.material; const copy = s; _ = copy; }
        \\const A = @import("aegis").Secret;
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

test "aegis pack report acceptance never completes invalid input even with file gates" {
    var project = try fixture("pub fn bad() void { const broken = ; }");
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(!report.complete);
    var gated = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules, .files = &.{.{ .file = P.FileId.fromRaw(0), .config = .{ .selections = &.{.{ .rule = pack.access, .level = .gate }} } }} });
    defer gated.deinit();
    try std.testing.expect(!gated.complete);
}

test "aegis pack direct cleanup twice and use after cleanup have local witnesses" {
    var project = try fixture(
        \\const S = @import("aegis").Secret;
        \\pub fn f() void { var s = S(u32).init(1); s.deinit(); s.deinit(); _ = &s; }
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), count(report, pack.cleanup)); // safe: fixture counts are representable.
}

test "aegis pack type factory is not acquisition and repeated defers have witnesses" {
    var project = try fixture(
        \\const S = @import("aegis").Secret;
        \\pub fn template() void { const T = S(u32); _ = &T; }
        \\pub fn repeated() void { var s = S(u32).init(1); defer s.deinit(); defer s.deinit(); }
        \\pub fn late() void { var s = S(u32).init(1); s.deinit(); defer s.deinit(); }
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), count(report, pack.cleanup)); // safe: two explicit repeated cleanup witnesses, no type-template obligation.
    for (report.diagnostics) |d| try std.testing.expect(d.span.line != 2);
}

test "morning adopted aegis gate accepts selection and preserves finding levels" {
    var project = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }");
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: one direct backing access.
    try std.testing.expectEqual(glint.Config.Level.gate, report.diagnostics[0].level);
}

test "morning adopted scalar gate reports bypasses and blocks unresolved receivers" {
    var project = try fixture("const Checked = @import(\"aegis\").int.Checked; pub fn f() void { const v = Checked(u32).init(1); _ = v.raw() + 2; }");
    defer project.deinit();
    const gated: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.scalar, .level = .gate }} };
    var report = try glint.runConfigured(std.testing.allocator, &project, gated, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: one raw arithmetic bypass.
    try std.testing.expectEqual(glint.Config.Level.gate, report.diagnostics[0].level);
    var unknown = try fixture("pub fn f(v: anytype) void { _ = v.raw() + 2; }");
    defer unknown.deinit();
    var incomplete = try glint.runConfigured(std.testing.allocator, &unknown, gated, .{ .project_rules = &pack.rules });
    defer incomplete.deinit();
    try std.testing.expect(!incomplete.complete);
}

test "adopted gates retain unresolved obligations and known unrelated receivers" {
    const cases = .{
        .{ pack.access, "pub fn f(v: anytype) void { _ = v.material; }" },
        .{ pack.access, "pub fn f(comptime T: type, v: *T) void { _ = v.material; }" },
        .{ pack.copies, "pub fn f(v: anytype) void { const copy = v; _ = copy; }" },
        .{ pack.copies, "pub fn f(v: anytype) *const u32 { return v.expose(); }" },
        .{ pack.cleanup, "pub fn f(T: type) void { var v = T.init(1); _ = &v; }" },
        .{ pack.capacity, "pub fn f(T: type, gpa: anytype, bytes: []u8) void { _ = T.adopt(gpa, bytes, 0); }" },
    };
    inline for (cases) |case| {
        var project = try fixture(case[1]);
        defer project.deinit();
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = case[0], .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expect(!report.complete);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: unresolved ownership records coverage rather than an allegation.
    }
    var plain = try fixture("const Plain = struct { material: u32 }; pub fn f(v: Plain) void { _ = v.material; }");
    defer plain.deinit();
    var clean = try glint.runConfigured(std.testing.allocator, &plain, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer clean.deinit();
    try std.testing.expect(clean.complete);
    try std.testing.expectEqual(@as(usize, 0), clean.diagnostics.len); // safe: resolved unrelated containers carry no published operation obligation.
}

test "a copy of plain data is decided by what the copy or its source declares" {
    var project = try fixture(
        \\const S = @import("aegis").Secret;
        \\fn Unwrapped(comptime F: type) type {
        \\    return switch (@typeInfo(F)) {
        \\        .optional => |o| o.child,
        \\        else => F,
        \\    };
        \\}
        \\fn width(bytes: []const u8) usize {
        \\    return bytes.len;
        \\}
        \\pub fn f(v: anytype, comptime F: type, rows: *[3][4]usize) usize {
        \\    const now: ?bool = v;
        \\    const left = comptime width("ab");
        \\    var col: usize = left;
        \\    col += 1;
        \\    const Child = Unwrapped(F);
        \\    const Value = Child;
        \\    const before = &rows[0];
        \\    const spent = before;
        \\    var out: [2]u8 = "ab".*;
        \\    out[0] = 'c';
        \\    const final = out;
        \\    _ = now;
        \\    _ = Value;
        \\    return col + spent[0] + final[0];
        \\}
        \\pub fn g(v: S(u32)) void {
        \\    const kept: S(u32) = v;
        \\    _ = kept;
        \\}
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.copies, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    // The owner copied into a declared owner is still the one witness.
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: one owner copy in the fixture.
    try std.testing.expectEqual(@as(u32, 28), report.diagnostics[0].span.line); // safe: the fixture's owner-copy line fits u32.
}

test "owner value parameter copy differs from borrowed pointer alias" {
    var project = try fixture(
        \\const S = @import("aegis").Secret;
        \\pub fn value(v: S(u32)) void { const copy = v; _ = copy; }
        \\pub fn borrow(v: *S(u32)) void { const alias = v; _ = alias; }
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.copies, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: the value copy is the sole ownership witness.
    try std.testing.expectEqual(@as(u32, 2), report.diagnostics[0].span.line); // safe: the fixture value-copy line fits u32.
}

test "adopted aegis gates preserve escaped operation spellings" {
    const operations = [_][]const u8{ "material", "init", "deinit", "raw", "adopt", "acquire", "owner", "data", "allocation" };
    const source =
        \\const Secret = @import("aegis").Secret;
        \\const Guarded = @import("aegis").Guarded;
        \\const Bytes = @import("aegis").SecretBytes;
        \\const Checked = @import("aegis").int.Checked;
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
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var escaped: []const u8 = source;
    for (operations) |operation| {
        escaped = try std.mem.replaceOwned(u8, a, escaped, try a.print(".{s}", .{operation}), try a.print(".@\"{s}\"", .{operation}));
    }
    var adopted = config;
    var selections = config.selections[0..5].*;
    for (&selections) |*selection| selection.level = .gate;
    adopted.selections = &selections;
    var plain_project = try fixture(source);
    defer plain_project.deinit();
    var escaped_project = try fixture(escaped);
    defer escaped_project.deinit();
    try std.testing.expectEqual(.parsed, plain_project.files[0].status);
    try std.testing.expectEqual(.parsed, escaped_project.files[0].status);
    var plain = try glint.runConfigured(std.testing.allocator, &plain_project, adopted, .{ .project_rules = &pack.rules });
    defer plain.deinit();
    var quoted = try glint.runConfigured(std.testing.allocator, &escaped_project, adopted, .{ .project_rules = &pack.rules });
    defer quoted.deinit();
    for (adopted.selections) |selection| try std.testing.expectEqual(count(plain, selection.rule), count(quoted, selection.rule));
    try std.testing.expectEqual(plain.complete, quoted.complete);
    try std.testing.expectEqual(plain.coverage.len, quoted.coverage.len);
}

test "escaped acquisition cleanup and guard type keep direct gate witnesses" {
    const cases = .{
        .{ pack.cleanup, "const S = @import(\"aegis\").Secret; pub fn f() void { var s = S(u32).@\"init\"(1); _ = &s; }" },
        .{ pack.cleanup, "const S = @import(\"aegis\").Secret; pub fn f() void { var s = S(u32).@\"init\"(1); s.@\"deinit\"(); s.@\"deinit\"(); }" },
        .{ pack.access, "const G = @import(\"aegis\").Guarded; pub fn f(g: *G(u32).@\"Guard\") void { _ = g.@\"owner\"; }" },
    };
    inline for (cases) |case| {
        var project = try fixture(case[1]);
        defer project.deinit();
        try std.testing.expectEqual(.parsed, project.files[0].status);
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = case[0], .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expect(report.complete);
        try std.testing.expectEqual(@as(usize, 1), count(report, case[0])); // safe: each source has one direct obligation witness.
    }
}

// The flat layout the first published aegis used: one file per declaration, a root that names
// them. Its bytes share nothing with the pinned revision's, only the public names.
fn scalarFile(comptime names: []const []const u8) []const u8 {
    comptime var text: []const u8 = "fn check(comptime R: type) void { _ = R; }\n";
    inline for (names) |name| text = text ++ "pub fn " ++ name ++ "(comptime Repr: type) type {\n    comptime check(Repr);\n    return struct {\n        value: Repr,\n        pub fn init(v: Repr) @This() { return .{ .value = v }; }\n        pub fn fromRaw(v: Repr) @This() { return .{ .value = v }; }\n        pub fn raw(self: @This()) Repr { return self.value; }\n    };\n}\n";
    return text;
}
const flat_root_head =
    \\pub const Secret = @import("Secret.zig").Secret;
    \\pub const SecretBytes = @import("SecretBytes.zig");
    \\
;
const flat_root_tail =
    \\pub const int = @import("int.zig");
    \\pub const id = @import("id.zig");
    \\pub const units = @import("units.zig");
;
const flat_root = flat_root_head ++ "pub const Guarded = @import(\"Guarded.zig\").Guarded;\n" ++ flat_root_tail;
const flat_secret =
    \\pub fn Secret(comptime T: type) type {
    \\    comptime validate(T);
    \\    return struct {
    \\        const Self = @This();
    \\        material: T,
    \\        pub fn init(value: T) Self { return .{ .material = value }; }
    \\        pub fn expose(self: *const Self) *const T { return &self.material; }
    \\        pub fn deinit(self: *Self) void { self.* = undefined; }
    \\    };
    \\}
    \\fn validate(comptime T: type) void { _ = T; }
;
const flat_guarded =
    \\pub fn Guarded(comptime T: type) type {
    \\    return struct {
    \\        const Self = @This();
    \\        lock: bool = false,
    \\        data: T,
    \\        pub fn init(value: T) Self { return .{ .data = value }; }
    \\        pub fn acquire(owner: *Self) Guard {
    \\            owner.lock = true;
    \\            return .{ .owner = owner };
    \\        }
    \\        pub const Guard = struct {
    \\            owner: *Self,
    \\            pub fn value(guard: *const Guard) *T { return &guard.owner.data; }
    \\            pub fn deinit(guard: *Guard) void { guard.owner.lock = false; }
    \\        };
    \\    };
    \\}
;
const flat_bytes =
    \\const std = @import("std");
    \\allocation: []u8,
    \\used_len: usize,
    \\gpa: std.mem.Allocator,
    \\pub fn adopt(gpa: std.mem.Allocator, allocation: []u8, used_len: usize) !@This() {
    \\    return .{ .allocation = allocation, .used_len = used_len, .gpa = gpa };
    \\}
    \\pub fn deinit(self: *@This()) void { _ = self; }
;
const flat_int = scalarFile(&.{ "Checked", "Saturating", "Ranged" });
const flat_id = scalarFile(&.{ "Id", "NonZero", "Counter" });
const flat_units = scalarFile(&.{ "Count", "Bytes", "Bits", "Duration", "Instant" });
const Flat = struct { root: []const u8 = flat_root, vault: []const u8 = "", library_selected: bool = false };
fn flatFixture(bytes: []const u8, options: Flat) !P {
    const selected = options.library_selected;
    var inputs = [_]P.Input{
        .{ .name = "consumer", .bytes = bytes },
        .{ .name = "root.zig", .bytes = options.root, .selected = selected },
        .{ .name = "Secret.zig", .bytes = flat_secret, .selected = selected },
        .{ .name = "Guarded.zig", .bytes = flat_guarded, .selected = selected },
        .{ .name = "SecretBytes.zig", .bytes = flat_bytes, .selected = selected },
        .{ .name = "int.zig", .bytes = flat_int, .selected = selected },
        .{ .name = "id.zig", .bytes = flat_id, .selected = selected },
        .{ .name = "units.zig", .bytes = flat_units, .selected = selected },
        .{ .name = "vault.zig", .bytes = options.vault, .selected = false },
    };
    const imports = [_]P.Import{
        .{ .from = P.FileId.fromRaw(0), .spelling = "aegis", .target = P.FileId.fromRaw(1) },
        .{ .from = P.FileId.fromRaw(0), .spelling = "vault", .target = P.FileId.fromRaw(8) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "Secret.zig", .target = P.FileId.fromRaw(2) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "Guarded.zig", .target = P.FileId.fromRaw(3) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "SecretBytes.zig", .target = P.FileId.fromRaw(4) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "int.zig", .target = P.FileId.fromRaw(5) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "id.zig", .target = P.FileId.fromRaw(6) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "units.zig", .target = P.FileId.fromRaw(7) },
    };
    return P.init(std.testing.allocator, &inputs, &imports, .{});
}
const every_site =
    \\const aegis = @import("aegis");
    \\pub fn f(gpa: anytype, allocation: []u8, n: usize) !void {
    \\    var s = aegis.Secret(u32).init(9);
    \\    defer s.deinit();
    \\    _ = s.material;
    \\    const copy = s;
    \\    _ = copy;
    \\    var g = aegis.Guarded(u32).init(0);
    \\    _ = g.data;
    \\    var held = g.acquire();
    \\    defer held.deinit();
    \\    _ = held.owner;
    \\    const a = aegis.int.Checked(u32).init(1);
    \\    _ = a.raw() + 2;
    \\    _ = @as(u8, @intCast(a.raw()));
    \\    var b = try aegis.SecretBytes.adopt(gpa, allocation[0..n], n);
    \\    defer b.deinit();
    \\    _ = b.allocation;
    \\}
;
fn expectEverySite(report: glint.Report) !void {
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 4), count(report, pack.access)); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.copies)); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 2), count(report, pack.scalar)); // safe: fixture counts are representable.
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.capacity)); // safe: fixture counts are representable.
}
test "aegis is recognized by its published names in the pinned layout and the first flat layout" {
    var pinned = try fixture(every_site);
    defer pinned.deinit();
    var pinned_report = try glint.runConfigured(std.testing.allocator, &pinned, config, .{ .project_rules = &pack.rules });
    defer pinned_report.deinit();
    try expectEverySite(pinned_report);
    var flat = try flatFixture(every_site, .{});
    defer flat.deinit();
    var flat_report = try glint.runConfigured(std.testing.allocator, &flat, config, .{ .project_rules = &pack.rules });
    defer flat_report.deinit();
    try expectEverySite(flat_report);
}
test "a standalone aegis namespace module is recognized" {
    var project = try fixture("const Id = @import(\"aegis.id\").Id; const Tag = struct {}; pub fn f() void { const v = Id(Tag, u32).fromRaw(1); _ = v.raw() + 2; }");
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.scalar, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: one raw arithmetic bypass.
}
test "identical source under another module is not aegis" {
    var project = try flatFixture("const S = @import(\"vault\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }", .{ .vault = "pub const Secret = @import(\"Secret.zig\").Secret;" });
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: the vault module's Secret is not aegis's.
}
test "a published member that disappears is reported where aegis is imported, never a quiet gate" {
    const dropped = flat_root_head ++ flat_root_tail;
    var project = try flatFixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }", .{ .root = dropped });
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    // The secret is still found, so its finding stands; the run cannot claim the library was recognized in full.
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: the secret's backing access.
    try std.testing.expect(!report.complete);
    var detail: ?[]const u8 = null;
    for (report.coverage) |entry| if (entry.rule != null) {
        detail = entry.detail;
    };
    try std.testing.expectEqualStrings("published member Guarded of aegis does not resolve (unresolved); its operations are not recognized in this file", detail.?);
}
test "aegis's own files are its safe-type internals" {
    var project = try flatFixture(every_site, .{ .library_selected = true });
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    // Only the consumer is checked: the guard's own `owner.lock` and the secret's `material` are not findings.
    try expectEverySite(report);
}

fn scalarFindings(project: *P) !usize {
    const gated: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.scalar, .level = .gate }} };
    var report = try glint.runConfigured(std.testing.allocator, project, gated, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    return count(report, pack.scalar);
}

test "scalar receivers are known through a type function's method, a captured payload and an orelse" {
    var project = try fixture(
        \\const Id = @import("aegis").id.Id;
        \\const Index = Id(struct {}, u16);
        \\fn Handle(comptime checked: bool) type {
        \\    return enum(if (checked) u64 else u16) {
        \\        none = 0,
        \\        _,
        \\        pub fn index(h: @This()) ?Index {
        \\            return if (@backingInt(h) == 0) null else .fromRaw(1);
        \\        }
        \\    };
        \\}
        \\const Link = Handle(true);
        \\pub fn f(link: Link, limit: u16) bool {
        \\    if (link.index()) |i| {
        \\        if (i.raw() < limit) return true;
        \\    }
        \\    const j = link.index() orelse return false;
        \\    return j.raw() == limit;
        \\}
    );
    defer project.deinit();
    try std.testing.expectEqual(@as(usize, 2), try scalarFindings(&project)); // safe: two raw comparisons, both decided.
}

test "scalar receivers are known through a type another file of the program names" {
    var project = try aegis_sources.projectWith(std.testing.allocator,
        \\const lib = @import("lib");
        \\pub fn f(len: lib.Length, plain: u16) bool {
        \\    const offset: lib.Offset = .fromRaw(plain);
        \\    return len.raw() != 12 or offset.raw() != 0;
        \\}
    ,
        \\const deps = struct {
        \\    pub const aegis = @import("aegis");
        \\};
        \\const Tag = struct {};
        \\pub const Length = deps.aegis.units.Bytes(u16);
        \\pub const Offset = deps.aegis.id.Id(Tag, u32);
    );
    defer project.deinit();
    try std.testing.expectEqual(@as(usize, 2), try scalarFindings(&project)); // safe: two raw comparisons, decided.
}

test "a scalar receiver is known through an unwrapped optional" {
    var project = try fixture(
        \\const Index = @import("aegis").id.Id(struct {}, u16);
        \\pub fn f(maybe: ?Index, limit: u16) bool {
        \\    return maybe.?.raw() < limit;
        \\}
    );
    defer project.deinit();
    try std.testing.expectEqual(@as(usize, 1), try scalarFindings(&project)); // safe: one raw comparison, decided.
}

/// One rule gated over `source`: whether the run decided every site, and how many findings.
fn judged(source: []const u8, rule: glint.Rule) !struct { complete: bool, findings: usize } {
    var project = try fixture(source);
    defer project.deinit();
    try std.testing.expectEqual(.parsed, project.files[0].status);
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    return .{ .complete = report.complete, .findings = count(report, rule) };
}
fn expectJudged(source: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    const got = try judged(source, rule);
    try std.testing.expectEqual(complete, got.complete);
    try std.testing.expectEqual(findings, got.findings);
}

test "receivers bound by captures are decided by what they bind" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst Plain = struct { data: u32, lock: u32 };\n";
    // A switch prong's payload is the union field its item names.
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: G(u32) };\npub fn f(u: *const U) void { switch (u.*) { .a => |p| _ = p.data, .b => {} } }", pack.access, true, 0);
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: G(u32) };\npub fn f(u: *U) void { switch (u.*) { .a => {}, .b => |*g| _ = g.data } }", pack.access, true, 1);
    // Prong items whose payloads differ, and an `else` prong of a union, stay undecided.
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: G(u32) };\npub fn f(u: U) void { switch (u) { .a, .b => |x| _ = x.data } }", pack.access, false, 0);
    // A `for` capture is its slice's element; a range's is a number.
    try expectJudged(head ++ "pub fn f(items: []Plain) void { for (items, 0..) |item, i| { _ = item.data; _ = i; } }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(items: []G(u32)) void { for (items) |*item| _ = item.data; }", pack.access, true, 1);
    // An array written in place, its element type named: a capture is that type.
    try expectJudged(head ++ "pub fn f() void { const Case = struct { state: u8, data: u8 }; for ([_]Case{ .{ .state = 0, .data = 1 } }) |case| { _ = case.state; _ = case.data; } }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(a: G(u32), b: G(u32)) void { for ([_]G(u32){ a, b }) |g| _ = g.data; }", pack.access, true, 1);
    // An `if` or `while` payload is its condition's optional or error-union payload.
    try expectJudged(head ++ "fn next() ?*Plain { return null; }\npub fn f() void { while (next()) |p| _ = p.lock; }", pack.access, true, 0);
    try expectJudged(head ++ "fn next() ?*G(u32) { return null; }\npub fn f() void { if (next()) |g| _ = g.lock; }", pack.access, true, 1);
}

test "receivers through locals, unwrapping, branches and generic results are decided" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst Plain = struct { data: u32, lock: u32 };\nconst Holder = struct { plain: Plain, guarded: G(u32) };\n";
    // A local initialised from a field.
    try expectJudged(head ++ "pub fn f(h: *Holder) void { const p = h.plain; _ = p.data; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(h: *Holder) void { const g = &h.guarded; _ = g.data; }", pack.access, true, 1);
    // `catch`, `orelse` and `.?` give the payload; `!T` results are error unions.
    try expectJudged(head ++ "fn make() !Plain { return .{ .data = 0, .lock = 0 }; }\npub fn f() void { const p = make() catch return; _ = p.data; }", pack.access, true, 0);
    try expectJudged(head ++ "fn make() !G(u32) { return .init(0); }\npub fn f() void { const g = make() catch return; _ = g.data; }", pack.access, true, 1);
    try expectJudged(head ++ "fn find() ?*Plain { return null; }\npub fn f() void { _ = (find() orelse return).data; _ = find().?.lock; }", pack.access, true, 0);
    // A `switch` choosing between types is each of them: decided when they agree.
    try expectJudged(head ++ "const os = @import(\"builtin\").os.tag;\nconst E = switch (os) { .linux => Plain, .macos => struct { data: i64 }, else => @compileError(\"no\") };\npub fn f(e: *const E) void { _ = e.data; }", pack.access, true, 0);
    try expectJudged(head ++ "const os = @import(\"builtin\").os.tag;\nconst E = switch (os) { .linux => Plain, else => G(u32) };\npub fn f(e: *E) void { _ = e.data; }", pack.access, false, 0);
    // A generic function returning its `comptime T: type` parameter returns that type.
    try expectJudged(head ++ "fn zeroes(comptime T: type) T { return undefined; }\npub fn f() void { const p = zeroes(Plain); _ = p.data; }", pack.access, true, 0);
    try expectJudged(head ++ "fn zeroes(comptime T: type) T { return undefined; }\npub fn f() void { const g = zeroes(G(u32)); _ = g.data; }", pack.access, true, 1);
    // A method of a container a type function made reads its parameters as the call's arguments.
    const boxes = "fn Box(comptime T: type) type { return struct { item: T, pub fn get(self: *@This()) *T { return &self.item; } }; }\n";
    try expectJudged(head ++ boxes ++ "pub fn f(b: *Box(Plain)) void { _ = b.get().data; }", pack.access, true, 0);
    try expectJudged(head ++ boxes ++ "pub fn f(b: *Box(G(u32))) void { _ = b.get().data; }", pack.access, true, 1);
    // A number from operators no aegis type takes.
    try expectJudged(head ++ "pub fn f(bytes: []const u8) void { const n = bytes.len - 1; var m = n; _ = &m; }", pack.copies, true, 0);
}

test "a copied pointer is an alias, an owner copy is still found" {
    const head = "const S = @import(\"aegis\").Secret;\n";
    try expectJudged(head ++ "pub fn f(s: ?*S(u32)) void { var p = s; _ = &p; }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f() void { var s = S(u32).init(1); defer s.deinit(); const copy = s; _ = copy; }", pack.copies, true, 1);
}

test "cleanup paths through branches, deferred releases and loops are decided" {
    const head = "const G = @import(\"aegis\").Guarded;\nfn ready() bool { return true; }\nfn hand(_: anytype) void {}\n";
    // Released in a branch that returns, and at the end of the fallthrough.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) { held.deinit(); return; } held.value().* += 1; held.deinit(); }", pack.cleanup, true, 0);
    // Deferred: every exit runs it, and a loop's own `break` does not leave the block.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) u32 { var held = g.acquire(); defer held.deinit(); while (true) { if (ready()) break; } for (0..3) |i| if (i == held.value().*) return 1; return 0; }", pack.cleanup, true, 0);
    // Released again after a deferred release: a witness.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); defer held.deinit(); held.deinit(); }", pack.cleanup, true, 1);
    // A return while held, a hand-off of its address, a release nested where the walk does not
    // follow: undecided, never a claim.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) return; held.deinit(); }", pack.cleanup, false, 0);
    try expectJudged(head ++ "fn take(h: anytype) void { h.deinit(); }\npub fn f(g: *G(u32)) void { var held = g.acquire(); take(&held); }", pack.cleanup, false, 0);
    // Lent to a function that hands it back held, it is still the caller's to release.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); hand(&held); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); while (ready()) held.deinit(); }", pack.cleanup, false, 0);
    // Branches that leave it in different states.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) held.deinit(); }", pack.cleanup, false, 0);
    // Released, then acquired again into the same local and released.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); held.deinit(); held = g.acquire(); held.deinit(); }", pack.cleanup, true, 0);
}

test "receivers through elements, slices, joined arrays and generic results written around T are decided" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst S = @import(\"aegis\").Secret;\nconst Plain = struct { data: u32, lock: u32 };\nconst Event = union(enum) { data: struct { bytes: []const u8 }, other: void };\n";
    // An element of an array, of an optional's array, of a pointer to an array or of a slice.
    try expectJudged(head ++ "pub fn f(es: [2]?Event) void { _ = es[0].?.data.bytes; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(ps: *const [2]Plain, qs: []const Plain) void { _ = ps[0].data; _ = qs[1].lock; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(gs: []G(u32)) void { _ = gs[0].data; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f() void { var gs: [2]G(u32) = undefined; _ = &gs; _ = gs[1].lock; }", pack.access, true, 1);
    // A slice of an array, dereferenced, is an array of its elements.
    try expectJudged(head ++ "pub fn f() void { var ps: [2]Plain = undefined; _ = &ps; const kept = ps[0..1].*; var copies: [1]Plain = kept; _ = &copies; }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(ss: []S(u32)) void { const window = ss[1..]; _ = window[0].material; }", pack.access, true, 1);
    // Literals joined are plain data.
    try expectJudged(head ++ "pub fn f() void { const text = \"ab\" ++ \"cd\"; const copy = text; _ = copy; }", pack.copies, true, 0);
    // A method generic in `T` that returns `E!*T`, called on a value, returns a pointer to the argument.
    const allocator = "const A = struct { pub fn create(a: A, comptime T: type) error{OutOfMemory}!*T { _ = a; return undefined; } };\n";
    try expectJudged(head ++ allocator ++ "pub fn f(gpa: A) !void { const p = try gpa.create(Plain); _ = p.data; }", pack.access, true, 0);
    try expectJudged(head ++ allocator ++ "pub fn f(gpa: A) !void { const g = try gpa.create(G(u32)); _ = g.data; }", pack.access, true, 1);
}

test "copies of vectors, payloads, if expressions and labeled blocks of plain data are decided" {
    const head = "const S = @import(\"aegis\").Secret;\nfn size(n: usize) ?usize { return n; }\nfn ready() bool { return true; }\n";
    try expectJudged(head ++ "pub fn f(v: @Vector(4, u8)) void { const w: @Vector(4, u16) = v; const copy = w; _ = copy; }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(n: usize) ?usize { const o = size(n) orelse return null; var p = o; _ = &p; return p; }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(n: usize) ?usize { var o = if (ready()) blk: { if (n == 0) break :blk 1; break :blk size(n) orelse return null; } else size(n + 1) orelse return null; const at = o; o += 1; return at; }", pack.copies, true, 0);
    // A labeled block that breaks with an owner is no plain data: its copy is left undecided.
    try expectJudged(head ++ "pub fn f() void { var s = blk: { break :blk S(u32).init(1); }; defer s.deinit(); const copy = s; _ = copy; }", pack.copies, false, 0);
}

test "generic parameters are what the project's own calls pass, when no consumer can call by name" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst Plain = struct { data: u32, owner: u32 };\n";
    // A private generic: its `anytype` is the union of what its callers pass.
    try expectJudged(head ++ "fn look(p: anytype) void { _ = p.owner; }\npub fn f(x: *Plain) void { look(x); }", pack.access, true, 0);
    // Callers that disagree, one passing an owner: undecided, as any choice between types that disagree.
    try expectJudged(head ++ "fn look(p: anytype) void { _ = p.data; }\npub fn f(x: *Plain, g: *G(u32)) void { look(x); look(g); }", pack.access, false, 0);
    try expectJudged(head ++ "fn look(p: anytype) void { _ = p.data; }\npub fn f(g: *G(u32)) void { look(g); }", pack.access, true, 1);
    // Through a method of a container, and a caller that is itself generic.
    try expectJudged(head ++ "const Box = struct { fn look(_: *const Box, p: anytype) void { _ = p.owner; } };\nfn pass(b: *const Box, p: anytype) void { b.look(p); }\npub fn f(b: *const Box, x: *Plain) void { pass(b, x); }", pack.access, true, 0);
    // A `comptime` type parameter of a private type function.
    try expectJudged(head ++ "fn Holder(comptime T: type) type { return struct { pub fn get(t: *T) void { _ = t.data; } }; }\npub fn f(x: *Plain) void { Holder(Plain).get(x); }", pack.access, true, 0);
    // A method's own generic, called on a pointer the caller's generic was given.
    try expectJudged(head ++ "const Sched = struct { processors: []Plain, monitor: ?*Monitor };\nconst Monitor = struct {\n    samples: []u32,\n    pub fn run(m: *Monitor, s: anytype) void { for (s.processors, m.samples) |*p, *sample| { _ = m.look(s, p, sample); } }\n    fn look(m: *Monitor, s: anytype, p: anytype, sample: *u32) bool { _ = m; _ = s; _ = sample; _ = p.owner; return false; }\n};\npub fn go(s: *Sched) void { s.monitor.?.run(s); }", pack.access, true, 0);
    // Taken other than by a call, its arguments are not all known: undecided.
    try expectJudged(head ++ "fn look(p: anytype) void { _ = p.owner; }\npub fn f() void { const taken = look; _ = taken; }", pack.access, false, 0);
}

test "a type function's result written with reflection is read at its call" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst Op = struct { owner: u32 };\n";
    const reflect =
        \\const Sink = struct { pub fn complete(s: *Sink, o: *Op) void { _ = s; _ = o; } };
        \\fn OpOf(comptime SinkPtr: type) type {
        \\    const S = @typeInfo(SinkPtr).pointer.child;
        \\    return @typeInfo(@typeInfo(@TypeOf(S.complete)).@"fn".param_types[1].?).pointer.child;
        \\}
        \\fn dispatch(sink: anytype, address: usize) void { const o: *OpOf(@TypeOf(sink)) = @ptrFromInt(address); _ = o.owner; }
        \\fn poll(sink: anytype) void { dispatch(sink, 0); }
        \\pub fn run(s: *Sink) void { poll(s); }
        \\
    ;
    try expectJudged(head ++ reflect, pack.access, true, 0);
    // The result type of a function another reaches through `@typeInfo(@TypeOf(f)).@"fn".return_type`.
    const future =
        \\fn Future(comptime Result: type) type { return struct { result: Result, pub fn await(future: *@This()) Result { return future.result; } }; }
        \\fn start(function: anytype) Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) { return undefined; }
        \\const Message = struct { data: u32 };
        \\fn receive() Message { return undefined; }
        \\pub fn f() void { var pending = start(receive); const message = pending.await(); _ = message.data; }
        \\
    ;
    try expectJudged(head ++ future, pack.access, true, 0);
}

test "fields of a made container, choices without members and reflection over choices are decided" {
    const base =
        \\const builtin = @import("builtin");
        \\fn State(comptime S: type) type { return struct { storage: Storage = undefined, pub const Storage = union { node: u32, scratch: S }; }; }
        \\const PortScratch = struct { owner: *u32 };
        \\const Scratch = union { port: if (builtin.os.tag == .windows) PortScratch else void, other: void };
        \\const Op = struct { state: State(Scratch) = .{} };
        \\const Counted = struct { pub fn complete(c: *Counted, o: *Op) void { _ = c; _ = o; } };
        \\const Pressure = struct { pub fn complete(p: *Pressure, o: *Op) void { _ = p; _ = o; } };
        \\fn OpOf(comptime SinkPtr: type) type {
        \\    const Sink = @typeInfo(SinkPtr).pointer.child;
        \\    return @typeInfo(@typeInfo(@TypeOf(Sink.complete)).@"fn".param_types[1].?).pointer.child;
        \\}
        \\
    ;
    // A field of `State(Scratch)` is of the type the call passed; a `void` choice has no `owner`
    // and is a build where the access does not compile.
    try expectJudged(base ++ "pub fn f(o: *Op) void { const s = &o.state.storage.scratch.port; _ = s.owner; }", pack.access, true, 0);
    // Two sinks: each is reflected on its own and both give the same operation type.
    try expectJudged(base ++ "fn dispatch(sink: anytype, address: usize) void { const o: *OpOf(@TypeOf(sink)) = @ptrFromInt(address); const s = &o.state.storage.scratch.port; _ = s.owner; }\npub fn f(c: *Counted, p: *Pressure) void { dispatch(c, 0); dispatch(p, 0); }", pack.access, true, 0);
    // An enum's field of the function's name is no use of the function.
    try expectJudged(base ++ "const Kind = enum { look, other };\nfn look(p: anytype) void { _ = p.owner; }\npub fn f(s: *PortScratch) Kind { look(s); return .look; }", pack.access, true, 0);
}

test "every guarded owner's backing state and guard are its contract's, whichever lock it holds" {
    var project = try fixture(
        \\const aegis = @import("aegis");
        \\pub fn f(io: anytype) !void {
        \\    var b = aegis.BlockingGuarded(u32).init(0);
        \\    _ = b.data;
        \\    _ = b.mutex;
        \\    var held = try b.acquire(io);
        \\    defer held.deinit(io);
        \\    _ = held.owner;
        \\    var rw = aegis.RwGuarded(u32).init(0);
        \\    _ = rw.admitted;
        \\    var reading = try rw.read(io);
        \\    defer reading.deinit(io);
        \\    _ = reading.owner;
        \\    var spin = aegis.SpinRwGuarded(u32).init(0);
        \\    _ = spin.state;
        \\    var writing = spin.write();
        \\    defer writing.deinit();
        \\    _ = writing.value();
        \\}
        \\pub fn leak(io: anytype) void {
        \\    var b = aegis.BlockingGuarded(u32).init(0);
        \\    var g = b.acquireUncancelable(io);
        \\    _ = &g;
        \\}
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    // b.data, b.mutex, held.owner, rw.admitted, reading.owner, spin.state.
    try std.testing.expectEqual(@as(usize, 6), count(report, pack.access)); // safe: fixture counts are representable.
    // A guard acquired and never released.
    try std.testing.expectEqual(@as(usize, 1), count(report, pack.cleanup)); // safe: fixture counts are representable.
}

test "a guard read in a condition before its release, and one lent to a condition's wait, are decided" {
    const head = "const aegis = @import(\"aegis\");\n";
    // Read in an `if`'s condition and through its capture, then released.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *aegis.BlockingGuarded(?u32)) void { var held = b.acquireUncancelable(io); if (held.value().*) |v| { _ = v; } held.deinit(io); }", pack.cleanup, true, 0);
    // Acquired by `try`, its release deferred, lent to a wait that holds it again on return.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *aegis.BlockingGuarded(u32), c: *aegis.Condition) !void { var held = try b.acquire(io); defer held.deinit(io); while (held.value().* == 0) c.wait(io, &held, .none) catch |err| switch (err) { error.Timeout => return, else => |e| return e }; }", pack.cleanup, true, 0);
    // Lent anywhere else, its release may move: undecided.
    try expectJudged(head ++ "fn keep(g: anytype) void { _ = g; }\npub fn f(io: anytype, b: *aegis.BlockingGuarded(u32)) !void { var held = try b.acquire(io); defer held.deinit(io); keep(&held); }", pack.cleanup, false, 0);
    // A guard never released is still a finding when it was read in a condition.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *aegis.BlockingGuarded(?u32)) void { var held = b.acquireUncancelable(io); if (held.value().*) |v| { _ = v; } }", pack.cleanup, true, 1);
}

test "a guard lent to the program's own function is a borrow when every path hands it back held" {
    const head = "const aegis = @import(\"aegis\");\nconst B = aegis.BlockingGuarded(u32);\n";
    const owner = "pub fn f(io: anytype, b: *B, c: *aegis.Condition) void { var held = b.acquireUncancelable(io); defer held.deinit(io); give(io, b, c, &held); }";
    // Released and held again, a wait on the way, a loan on to another that does the same.
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { held.deinit(io); held.* = b.acquireUncancelable(io); again(io, b, c, held); }\nfn again(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { while (held.value().* == 0) { held.deinit(io); held.* = b.acquireUncancelable(io); c.wait(io, held, .none) catch return; } }\n" ++ owner, pack.cleanup, true, 0);
    // A method of the program's own, through its receiver.
    try expectJudged(head ++ "const S = struct { b: *B, fn give(s: *S, io: anytype, held: anytype) void { if (held.value().* == 0) return; held.deinit(io); held.* = s.b.acquireUncancelable(io); } };\npub fn f(io: anytype, s: *S) void { var held = s.b.acquireUncancelable(io); defer held.deinit(io); s.give(io, &held); }", pack.cleanup, true, 0);
    // One path returns with it released: no loan, undecided.
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { _ = c; held.deinit(io); if (held == held) return; held.* = b.acquireUncancelable(io); }\n" ++ owner, pack.cleanup, false, 0);
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { _ = b; _ = c; held.deinit(io); }\n" ++ owner, pack.cleanup, false, 0);
    // A release it defers is no loan.
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { _ = b; _ = c; defer held.deinit(io); }\n" ++ owner, pack.cleanup, false, 0);
}

test "an acquisition whose failure is caught is checked as one by `try` is" {
    const head = "const aegis = @import(\"aegis\");\nconst B = aegis.BlockingGuarded(u32);\n";
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquire(io) catch return; defer held.deinit(io); _ = held.value(); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquire(io) catch return; _ = held.value(); }", pack.cleanup, true, 1);
}
