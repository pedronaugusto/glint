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
    // A `switch` choosing between types is each of them, one per build: decided when they
    // agree, and an owner's backing field in the builds that choose the owner.
    try expectJudged(head ++ "const os = @import(\"builtin\").os.tag;\nconst E = switch (os) { .linux => Plain, .macos => struct { data: i64 }, else => @compileError(\"no\") };\npub fn f(e: *const E) void { _ = e.data; }", pack.access, true, 0);
    try expectJudged(head ++ "const os = @import(\"builtin\").os.tag;\nconst E = switch (os) { .linux => Plain, else => G(u32) };\npub fn f(e: *E) void { _ = e.data; }", pack.access, true, 1);
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

test "a guard through a loop is decided by the states its back edge and its exits agree on" {
    const head = "const aegis = @import(\"aegis\");\nconst B = aegis.BlockingGuarded(u32);\nfn ready() bool { return true; }\nfn wait() void {}\n";
    // Released and acquired again around a wait, left released by a return: a spare's wait.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) u32 { var held = b.acquireUncancelable(io); const value = held.value(); while (true) { if (value.* != 0) { const v = value.*; held.deinit(io); return v; } else {} held.deinit(io); wait(); held = b.acquireUncancelable(io); } }", pack.cleanup, true, 0);
    // Returned held from inside a loop that never ends otherwise: the caller's to release.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) B.Guard { var held = b.acquireUncancelable(io); if (!ready()) return held; _ = held.value(); while (true) { if (ready()) return held; wait(); } }", pack.cleanup, true, 0);
    // Its caller holds what it returns: released, or a finding.
    const give = "fn give(io: anytype, b: *B) B.Guard { var held = b.acquireUncancelable(io); _ = held.value(); return held; }\n";
    try expectJudged(head ++ give ++ "pub fn f(io: anytype, b: *B) void { var held = give(io, b); defer held.deinit(io); }", pack.cleanup, true, 0);
    try expectJudged(head ++ give ++ "pub fn f(io: anytype, b: *B) void { var held = give(io, b); _ = held.value(); }", pack.cleanup, true, 1);
    try expectJudged("const S = @import(\"aegis\").Secret;\nfn make() !S(u32) { return S(u32).init(1); }\npub fn f() !void { var s = try make(); _ = s.expose(); }", pack.cleanup, true, 1);
    // A pointer to an owner is no owner of the caller's.
    try expectJudged(head ++ "fn at(held: *B.Guard) *B.Guard { return held; }\npub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); defer held.deinit(io); const p = at(&held); _ = p; }", pack.cleanup, false, 0);
    // Released inside, left by `break`, released again after: decided, and a second release a witness.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (ready()) { held.deinit(io); if (ready()) break; held = b.acquireUncancelable(io); } else held.deinit(io); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (true) { if (ready()) { held.deinit(io); break; } } held.deinit(io); }", pack.cleanup, true, 1);
    // Every way out of the loop held, and no release after it: a finding.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (true) { if (ready()) break; _ = held.value(); wait(); } }", pack.cleanup, true, 1);
    // Ways out in different states, or a body that comes back released: undecided.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (ready()) { if (ready()) { held.deinit(io); break; } } held.deinit(io); }", pack.cleanup, false, 0);
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); for (0..2) |_| { held.deinit(io); continue; } }", pack.cleanup, false, 0);
    // A release the body defers runs as each pass ends.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { while (ready()) { var held = b.acquireUncancelable(io); defer held.deinit(io); if (ready()) continue; } }", pack.cleanup, true, 0);
    // A jump to an outer loop of the walk is not followed.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); outer: while (ready()) { while (ready()) { if (ready()) continue :outer; } } held.deinit(io); }", pack.cleanup, false, 0);
    // A `break` of the walk's loop inside an expression is one of its ways out.
    try expectJudged(head ++ "fn next() ?u32 { return null; }\npub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); defer held.deinit(io); while (true) { const n = next() orelse break; _ = n; } }", pack.cleanup, true, 0);
}

test "a guard's release handed off is a declared transfer" {
    const head = "const G = @import(\"aegis\").Guarded;\nfn ready() bool { return true; }\nfn park(_: anytype) void {}\n";
    // Handed to a callback's context: decided, as a futex wait parks its task.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) { held.deinit(); return; } held.value().* += 1; var handoff = held.handOff(); park(&handoff); if (ready()) return; }", pack.cleanup, true, 0);
    // Handed off in one branch, released in the other.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); var handoff: G(u32).Handoff = undefined; if (ready()) { handoff = held.handOff(); park(&handoff); } else held.deinit(); }", pack.cleanup, true, 0);
    // Released after the hand-off, or handed off after release: a witness each.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); var handoff = held.handOff(); park(&handoff); held.deinit(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); held.deinit(); var handoff = held.handOff(); park(&handoff); }", pack.cleanup, true, 1);
    // A hand-off thrown away hands nothing: the lock reaches the block's end held.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); _ = held.handOff(); }", pack.cleanup, true, 1);
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
    // A labeled block that breaks with an owner gives that owner: its copy is found.
    try expectJudged(head ++ "pub fn f() void { var s = blk: { break :blk S(u32).init(1); }; defer s.deinit(); const copy = s; _ = copy; }", pack.copies, true, 1);
}

test "generic parameters are what the project's own calls pass, when no consumer can call by name" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst Plain = struct { data: u32, owner: u32 };\n";
    // A private generic: its `anytype` is the union of what its callers pass.
    try expectJudged(head ++ "fn look(p: anytype) void { _ = p.owner; }\npub fn f(x: *Plain) void { look(x); }", pack.access, true, 0);
    // Callers that disagree, one passing an owner: the function is checked once per binding,
    // and the owner's binding reads its backing field.
    try expectJudged(head ++ "fn look(p: anytype) void { _ = p.data; }\npub fn f(x: *Plain, g: *G(u32)) void { look(x); look(g); }", pack.access, true, 1);
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

test "values initialized once and values one task owns keep their state behind their operations" {
    const head = "const aegis = @import(\"aegis\");\n";
    // A Once's and a Lazy's publication state, election lock, waiters and value.
    try expectJudged(head ++ "pub fn f(o: *aegis.Once(u32)) void { _ = o.state; _ = o.mutex; _ = o.changed; _ = o.data; }", pack.access, true, 4);
    try expectJudged(head ++ "pub fn f(l: *aegis.Lazy(u32)) void { _ = l.state; _ = l.data; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(l: *aegis.sync.Lazy(u32)) ?aegis.Lazy(u32).Ref { return l.get(); }", pack.access, true, 0);
    // A Confined value and the identity it checks.
    try expectJudged(head ++ "pub fn f(c: *aegis.Confined(u32)) void { _ = c.data; _ = c.owner; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(c: *aegis.Confined(u32), id: aegis.TaskIdentity) u32 { return c.value(id).*; }", pack.access, true, 0);
    // A copy of one made by its constructor duplicates its lock or its owner.
    try expectJudged(head ++ "pub fn f() void { var l = aegis.Lazy(u32).init(); const copy = l; _ = copy; _ = &l; }", pack.copies, true, 1);
    // Fields of the program's own of the same names are its own.
    try expectJudged(head ++ "const Mine = struct { state: u8, data: u8, owner: u8 };\npub fn f(m: *Mine) void { _ = m.state; _ = m.data; _ = m.owner; }", pack.access, true, 0);
}

test "a field of a container another module's type function makes is that container's" {
    var project = try aegis_sources.projectWith(std.testing.allocator,
        \\const lib = @import("lib");
        \\const Proxy = lib.Layer(u8, .{});
        \\var proxy: Proxy = .{ .state = 0, .base = 0 };
        \\pub const userdata: *anyopaque = &proxy.state;
    ,
        \\pub const Overrides = struct { read: ?u8 = null };
        \\pub fn Layer(comptime State: type, comptime overrides: Overrides) type {
        \\    comptime if (@sizeOf(State) == 0) @compileError("a layer keeps state");
        \\    _ = overrides;
        \\    return struct { state: State, base: u32 };
        \\}
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 0), count(report, pack.access)); // safe: fixture count is representable.
}

test "a backing field's name on a receiver nothing resolves is decided by what the program does with it" {
    const head = "const aegis = @import(\"aegis\");\nconst unknown = @import(\"unmapped\");\n";
    // A literal naming a field no aegis type with `state` has.
    try expectJudged(head ++ "var proxy: unknown.Layer = .{ .state = 0, .base = 1 };\npub fn f() *anyopaque { return &proxy.state; }", pack.access, true, 0);
    // A member read off the field is weighed against the field's declared type, which std
    // declares for these (an atomic, a mutex): with std unmapped here, undecided.
    try expectJudged(head ++ "pub fn f(o: unknown.Op) void { _ = o.state.storage; }", pack.access, false, 0);
    // A field used as a truth value or compared: `changed` is only a Once's, a condition (a
    // struct) no `if` or `==` takes.
    try expectJudged(head ++ "pub fn f(s: unknown.Span, changed: bool) bool { if (s.changed) return true; return s.changed == changed and !s.changed; }", pack.access, true, 0);
    // `data` is a generic owner's value, whatever it holds: undecided.
    try expectJudged(head ++ "pub fn f(s: unknown.Span) bool { return !s.data; }", pack.access, false, 0);
    // A literal naming only fields an aegis type has: undecided.
    try expectJudged(head ++ "var proxy: unknown.Layer = .{ .state = 0 };\npub fn f() *anyopaque { return &proxy.state; }", pack.access, false, 0);
}

test "receivers through a list's items, an if or switch expression's capture and a labeled block's breaks are decided" {
    const head = "const G = @import(\"aegis\").Guarded;\n";
    // A list as std makes one: public, so no caller settles its element; its items a slice of
    // the element whatever the alignment, which a check passes on as null by calling the
    // function again.
    const list = "pub const Alignment = enum(u8) { one = 1 };\npub fn Aligned(comptime T: type, comptime alignment: ?Alignment) type { if (alignment) |a| { if (@intFromEnum(a) == @alignOf(T)) return Aligned(T, null); } return struct { items: Slice = &.{}, pub const Slice = if (alignment) |a| ([]align(@intFromEnum(a)) T) else []T; }; }\npub fn List(comptime T: type) type { return Aligned(T, null); }\n";
    try expectJudged(head ++ list ++ "const L = struct { mutex: u32 };\npub const H = struct { listeners: List(*L) = .{} };\npub fn f(h: *H) void { for (h.listeners.items) |l| _ = l.mutex; }", pack.access, true, 0);
    try expectJudged(head ++ list ++ "const L = struct { guarded: G(u32) };\npub const H = struct { listeners: List(*L) = .{}, plain: Aligned(L, .one) = .{} };\npub fn f(h: *H) void { for (h.listeners.items) |l| _ = l.guarded.data; _ = h.plain.items[0].guarded.data; }", pack.access, true, 2);
    // A function that calls itself again with another type is not read past that call.
    try expectJudged(head ++ "pub fn Box(comptime T: type) type { if (@sizeOf(T) == 0) return Box(G(u32)); return struct { item: T }; }\nconst L = struct { mutex: u32 };\npub fn f(b: *Box(L)) void { _ = b.item.mutex; }", pack.access, false, 0);
    // An `if` expression whose other branch does not return a value.
    try expectJudged(head ++ "const T = struct { mutex: u32 };\nconst S = struct { table: ?T };\npub fn f(s: *S) void { const table = if (s.table) |*t| t else return; _ = table.mutex; }", pack.access, true, 0);
    // A `switch` expression's capture, its other prongs leaving.
    try expectJudged(head ++ "const Input = struct { state: u32 };\nconst Reply = union(enum) { input: Input, done: u32 };\nconst Server = struct { fn handle(_: *Server) !Reply { return .{ .done = 0 }; } };\nconst C = struct { server: *Server };\npub fn f(c: *C) !void { const reply = try c.server.handle(); const ir = switch (reply) { .input => |ir| ir, else => return }; _ = ir.state; }", pack.access, true, 0);
    // A labeled block's value is what its breaks give; `null` among them makes it optional.
    try expectJudged(head ++ "const Handler = struct { context: u32, fn read(h: Handler) !u32 { return h.context; } };\nconst R = struct { handler: Handler };\npub fn f(items: []*R) !void { const handler = found: { for (items) |r| if (r.handler.context == 0) break :found r.handler; break :found null; } orelse return; const got = try handler.read(); _ = got; }", pack.cleanup, true, 0);
    // A call through a function pointer field returns what its function type says.
    try expectJudged(head ++ "const Result = struct { mutex: u32 };\nconst Handler = struct { read: *const fn () error{Failed}!Result };\npub fn f(h: Handler) !void { var got = try h.read(); _ = &got; _ = got.mutex; }", pack.access, true, 0);
    try expectJudged(head ++ "const T = struct { mutex: u32 };\npub fn f(t: *T, ok: bool) void { const maybe = if (ok) t else null; _ = maybe.?.mutex; }", pack.access, true, 0);
}

test "every published type after the guards is recognized where aegis is imported, with no drift" {
    try expectJudged(
        \\const aegis = @import("aegis");
        \\pub fn f(a: *aegis.bounded.Array(u8, 4), q: *aegis.bounded.Queue(u8, 4), b: *aegis.bounded.Buffer(u8), l: aegis.bounded.Limit(u32), budget: *aegis.bounded.Budget(u32)) void {
        \\    _ = a.len(); _ = q.len(); _ = b.len(); _ = l.exceeds(1); _ = budget.remaining();
        \\}
    , pack.access, true, 0);
}

test "bounded storage, budgets and reservations keep their state behind their operations" {
    const head = "const aegis = @import(\"aegis\");\nconst bounded = aegis.bounded;\n";
    // The initialized prefix and its cursors, the buffer's extent and owner, a limit's maximum.
    try expectJudged(head ++ "pub fn f(a: *bounded.Array(u8, 4), r: *bounded.Ring(u8, 4)) void { _ = a.storage; _ = a.used; _ = r.head; }", pack.access, true, 3);
    try expectJudged(head ++ "pub fn f(b: *bounded.Buffer(u8), r: *bounded.RingBuffer(u8)) void { _ = b.storage; _ = b.gpa; _ = b.maximum; _ = r.used; }", pack.access, true, 4);
    try expectJudged(head ++ "pub fn f(l: bounded.Limit(u32)) u32 { return l.maximum; }", pack.access, true, 1);
    // A budget's charge and a reservation's borrowed budget, amount and witness.
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32), r: *bounded.Budget(u32).Reservation) void { _ = b.taken; _ = b.ceiling; _ = r.amount; _ = r.budget; }", pack.access, true, 4);
    // A method of the same name as a backing field is the operation, not the field.
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32), a: *bounded.Array(u8, 2)) void { _ = b.maximum(); _ = a.capacity(); }", pack.access, true, 0);
    // A copy of a budget forks its accounting; a copy of a reservation releases its charge twice.
    try expectJudged(head ++ "pub fn f() void { var b = bounded.Budget(u32).init(4); const copy = b; _ = copy; _ = &b; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32)) !void { var r = try b.reserve(1); defer r.release(); const copy = r; _ = copy; }", pack.copies, true, 1);
    // A limit is a value: copies of it are no second owner.
    try expectJudged(head ++ "pub fn f() void { const l = bounded.Limit(u32).init(4); const copy = l; _ = copy; }", pack.copies, true, 0);
    // A reservation is released once, or moved into storage the caller names.
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32)) !void { var r = try b.reserve(1); _ = &r; }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32)) !void { var r = try b.reserve(1); defer r.release(); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32), into: *bounded.Budget(u32).Reservation) !void { var r = try b.reserveKeeping(1, 1); r.moveInto(into); }", pack.cleanup, true, 0);
    // An allocated buffer is cleaned.
    try expectJudged(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator) !void { var b = try bounded.Buffer(u8).initAllocated(gpa, 1, 2); _ = b.len(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "fn none(_: *u8) void {}\npub fn f(gpa: @import(\"std\").mem.Allocator) !void { var b = try bounded.Buffer(u8).initAllocated(gpa, 1, 2); defer b.deinit(none); _ = b.len(); }", pack.cleanup, true, 0);
}

test "owners, result obligations and shared values are released once and never copied" {
    const head = "const aegis = @import(\"aegis\");\nfn clean(_: *u32) void {}\nconst O = aegis.own.Owned(u32, clean);\nconst M = aegis.own.MustUse(u32, \"read the count\");\nconst S = aegis.Shared(u32, clean);\n";
    try expectJudged(head ++ "pub fn f(o: *O, m: *M, s: *S) void { _ = o.data; _ = o.state; _ = m.pending; _ = s.block; }", pack.access, true, 4);
    try expectJudged(head ++ "pub fn f() void { var o = O.init(1); defer o.deinit(); const copy = o; _ = copy; }", pack.copies, true, 1);
    // A shared value's copy with `=` instead of `retain`.
    try expectJudged(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator) !void { var s = try S.create(gpa, 1); defer s.release(); const copy = s; _ = copy; }", pack.copies, true, 1);
    // Owned: released, taken out or moved; left live it is a finding.
    try expectJudged(head ++ "pub fn f() void { var o = O.init(1); _ = o.borrow(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f() void { var o = O.init(1); defer o.deinit(); _ = o.borrow(); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(out: *u32) void { var o = O.init(1); o.take(out); }", pack.cleanup, true, 0);
    // MustUse: discharged by take or a reasoned acknowledgment; its deinit alone discharges nothing.
    try expectJudged(head ++ "pub fn f() void { var m = M.init(1); defer m.deinit(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f() void { var m = M.init(1); defer m.deinit(); m.acknowledge(\"the count is logged elsewhere\"); }", pack.cleanup, true, 0);
    // Shared: each handle, the created one and each retained one, is released.
    try expectJudged(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator) !void { var s = try S.create(gpa, 1); defer s.release(); var other = s.retain(); _ = other.get(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator) !void { var s = try S.create(gpa, 1); defer s.release(); var other = s.retain(); defer other.release(); }", pack.cleanup, true, 0);
}

test "generational storage, staged payloads, machines, scopes, unparsed input and decisions keep their contracts" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\nconst Table = aegis.scope.Table(Tag);\n";
    // Slots behind keys; a copy of the map frees its storage twice.
    try expectJudged(head ++ "pub fn f(p: *aegis.handle.Pool(u32, Tag), m: *aegis.handle.SlotMap(u32, Tag)) void { _ = p.slots; _ = m.storage; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator, i: aegis.handle.Instance) !void { var m = try aegis.handle.SlotMap(u32, Tag).init(gpa, i, .{}); const copy = m; _ = copy; _ = &m; }", pack.copies, true, 1);
    try expectJudged(head ++ "fn none(_: *u32) void {}\npub fn f(gpa: @import(\"std\").mem.Allocator, i: aegis.handle.Instance) !void { var m = try aegis.handle.SlotMap(u32, Tag).init(gpa, i, .{}); defer m.deinit(none); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator, i: aegis.handle.Instance) !void { var m = try aegis.handle.SlotMap(u32, Tag).init(gpa, i, .{}); _ = m.len(); }", pack.cleanup, true, 1);
    // A domain copied issues its instances twice.
    try expectJudged(head ++ "pub fn f() void { var d = aegis.handle.Domain.init(1); const copy = d; _ = copy; _ = &d; }", pack.copies, true, 1);
    // A typed position's raw value in arithmetic.
    try expectJudged(head ++ "const I = aegis.handle.Index(Tag, u32);\npub fn f(i: I) u32 { return i.raw() + 1; }", pack.scalar, true, 1);
    // A staged payload and a machine's state.
    try expectJudged(head ++ "pub fn f(s: *Machine.At(.open, u32), r: *Machine.Runtime(u32)) void { _ = s.live; _ = r.payload; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f() void { var s = Machine.At(.open, u32).init(1); const copy = s; _ = copy; _ = &s; }", pack.copies, true, 1);
    // A scope is opened and ended; its reference's pointer is read through its check.
    try expectJudged(head ++ "pub fn f(t: *Table, r: aegis.scope.Ref(Tag, *u32)) void { _ = t.open_count; _ = r.generation; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(t: *Table) !void { const s = try t.open(); _ = &s; }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(t: *Table) !void { const s = try t.open(); defer s.end(); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(t: *Table) !void { const s = try t.open(); defer s.end(); const copy = s; _ = copy; }", pack.copies, true, 0);
    // Unparsed input read past its parser; a decision read past its declassification.
    try expectJudged(head ++ "pub fn f(u: aegis.input.Untrusted([]const u8)) []const u8 { return u.readForParse(); }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(a: *const [4]u8, b: *const [4]u8) bool { const c = aegis.secret.equal(4, a, b); return c.bit == 1; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(a: *const [4]u8, b: *const [4]u8) bool { const c = aegis.secret.equal(4, a, b); const copy = c; return copy.declassify(\"fixture\"); }", pack.copies, true, 0);
}

test "an adoption of a whole byte allocation from the same allocator, handed over alone, is decided" {
    const head = "const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\n";
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); @memset(buffer, 0); return Bytes.adopt(gpa, buffer, n); }", pack.capacity, true, 0);
    try expectJudged(head ++ "const S = struct { gpa: std.mem.Allocator };\npub fn f(s: *S, n: usize) !Bytes { const buffer = s.gpa.alloc(u8, n) catch return error.OutOfMemory; return Bytes.adopt(s.gpa, buffer, n); }", pack.capacity, true, 0);
    // Another allocator, a pending errdefer, a later use or an element wider than a byte stay review sites.
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator, other: std.mem.Allocator, n: usize) !Bytes { const buffer = try other.alloc(u8, n); return Bytes.adopt(gpa, buffer, n); }", pack.capacity, false, 0);
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); errdefer gpa.free(buffer); const b = try Bytes.adopt(gpa, buffer, n); return b; }", pack.capacity, false, 0);
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); const b = try Bytes.adopt(gpa, buffer, n); buffer[0] = 1; return b; }", pack.capacity, false, 0);
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); return Bytes.adopt(gpa, buffer[0..n], n); }", pack.capacity, false, 1);
}

test "an owner released on error by errdefer, carried out in what is returned, or moved out of a dead local is decided" {
    const head = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst Budget = aegis.bounded.Budget(u32);\nconst Charge = struct { jobs: Budget.Reservation, bytes: Budget.Reservation };\nfn none(_: *u8) void {}\n";
    // Two reservations returned in the caller's value; the first released when the second fails.
    try expectJudged(head ++ "pub fn f(a: *Budget, b: *Budget) !Charge { var jobs = a.reserve(1) catch return error.Busy; const bytes = b.reserve(2) catch { jobs.release(); return error.Busy; }; return .{ .jobs = jobs, .bytes = bytes }; }", pack.cleanup, true, 0);
    // Buffers released by errdefer while a later acquisition fails, then given to the caller's owner.
    try expectJudged(head ++ "const Pair = struct { a: aegis.bounded.Buffer(u8), b: aegis.bounded.Buffer(u8) };\npub fn f(gpa: std.mem.Allocator) !Pair { var a = try aegis.bounded.Buffer(u8).initAllocated(gpa, 1, 1); errdefer a.deinit(none); var b = try aegis.bounded.Buffer(u8).initAllocated(gpa, 1, 1); errdefer b.deinit(none); return .{ .a = a, .b = b }; }", pack.cleanup, true, 0);
    // Released on errors only, the owner still leaks on success.
    try expectJudged(head ++ "pub fn f(a: *Budget, gpa: std.mem.Allocator) ![]u8 { var r = try a.reserve(1); errdefer r.release(); const m = try gpa.alloc(u8, 1); return m; }", pack.cleanup, false, 0);
    // A guard moved out of an `if` capture nothing reads again.
    try expectJudged(head ++ "pub fn f(g: *aegis.Guarded(u32)) void { if (g.tryAcquire()) |free| { var held = free; held.deinit(); } }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(g: *aegis.Guarded(u32)) void { if (g.tryAcquire()) |free| { var held = free; held.deinit(); _ = free.value(); } }", pack.copies, true, 1);
    // A secret's bytes stay behind a copy: never a move.
    try expectJudged(head ++ "pub fn f() void { const s = aegis.Secret(u32).init(1); var t = s; t.deinit(); }", pack.copies, true, 1);
}

test "a member of a type is a declaration, never a backing field" {
    try expectJudged("const aegis = @import(\"aegis\");\npub fn max(comptime V: type) u32 { return V.maximum; }\npub fn f() u32 { return max(aegis.int.Ranged(u32, 0, 9)); }", pack.access, true, 0);
}

test "a member read of a backing field that is an array, a slice or a number is decided by the member" {
    const head = "const aegis = @import(\"aegis\");\nconst unknown = @import(\"unmapped\");\n";
    try expectJudged(head ++ "pub fn f(o: *unknown.Op) void { o.held.storage.scratch = 0; _ = o.held.storage.len; }", pack.access, false, 0);
    try expectJudged(head ++ "pub fn f(o: *unknown.Op) void { o.held.storage.scratch = 0; }", pack.access, true, 0);
}

test "receivers through comptime values, struct literals, calls by @call and a choice behind a pointer are decided" {
    const head = "const aegis = @import(\"aegis\");\nconst Plain = struct { data: u32, values: []const u8 = &.{} };\n";
    // `++` of two slices is an array of their elements.
    try expectJudged(head ++ "const Opt = struct { index: usize };\nconst Info = struct { options: []const Opt, positionals: []const Opt };\npub fn f(comptime info: Info) usize { var n: usize = 0; inline for (info.options ++ info.positionals) |o| n += o.index; return n; }", pack.access, true, 0);
    // `comptime x` has `x`'s type.
    try expectJudged(head ++ "fn all(comptime T: type) []const Plain { _ = T; return &.{}; }\npub fn f() usize { const ps = comptime all(u8); var n: usize = 0; inline for (ps) |p| n += p.values.len; return n; }", pack.access, true, 0);
    // A block's value given by an untyped struct literal is that literal's anonymous struct.
    try expectJudged(head ++ "const built = blk: { var t: [2]u8 = undefined; t[0] = 1; break :blk .{ .count = 1, .table = t }; };\npub fn f() u8 { return built.table[0]; }", pack.access, true, 0);
    // `@call` passes its tuple's elements as the arguments.
    try expectJudged(head ++ "fn run(c: anytype) u32 { return c.data; }\npub fn f(p: *Plain) u32 { return @call(.auto, run, .{p}); }", pack.access, true, 0);
    // A receiver that is a pointer to a type chosen per build, `void` where the build lacks it.
    try expectJudged(head ++ "const has = @import(\"builtin\").os.tag == .linux;\nconst Ring = struct { fn poll(_: *Ring, sink: anytype) u32 { return sink.data; } };\nconst Backend = union(enum) { ring: if (has) *Ring else void, none };\nfn poll(b: Backend, sink: anytype) u32 { return switch (b) { .ring => |r| if (has) r.poll(sink) else 0, .none => 0 }; }\npub fn f(b: Backend, p: *Plain) u32 { return poll(b, p); }", pack.access, true, 0);
    // A member of a choice that only one alternative has is that alternative's.
    try expectJudged(head ++ "const Full = struct { primary: u32 = 0 };\nconst State = struct { uring: if (@import(\"builtin\").os.tag == .linux) Full else struct { timed_out: bool = false } = .{} };\nconst Op = struct { state: State, data: u32 };\nfn settle(o: anytype) u32 { const ownership = &o.state.uring; return ownership.primary; }\npub fn f(o: *Op) u32 { return settle(o); }", pack.access, true, 0);
}

test "a function's callers are found past members of values that only fields can be" {
    const head = "const aegis = @import(\"aegis\");\nconst Plain = struct { data: u32 };\nfn run(c: anytype) u32 { return c.data; }\npub fn f(p: *Plain) u32 { return run(p); }\n";
    // Zig has no bound methods: a member of a value used other than by a call is a field.
    try expectJudged(head ++ "pub fn g(o: anytype) void { const s = &o.request; _ = &s.run; }", pack.access, true, 0);
    // A member written to, or read as a number, is a field.
    try expectJudged(head ++ "pub fn g(o: anytype, n: u32) void { o.run = n; if (o.run > 1) o.run -= 1; }", pack.access, true, 0);
    // An `anytype` parameter dereferenced is a pointer: its member passed on is a field.
    try expectJudged(head ++ "fn take(_: anytype) void {}\npub fn g(o: anytype) void { const T = @TypeOf(o.*); _ = T; take(o.run); }", pack.access, true, 0);
    // A receiver that may be a type may name the function itself: undecided.
    try expectJudged(head ++ "fn take(_: anytype) void {}\npub fn g(o: anytype) void { take(o.run); }", pack.access, false, 0);
}

test "an owner moved into a local aggregate is that aggregate's obligation" {
    const head = "const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\nconst Set = struct { storage: Bytes, n: usize, view: []const u8 = &.{} };\nconst Answer = union(enum) { set: Set, refused };\nconst E = error{ OutOfMemory, Refused };\nfn refused() E { return error.Refused; }\n";
    // Moved into a literal, the aggregate given to the caller: decided.
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator) E!Set { var storage = Bytes.init(gpa, 4) catch return error.OutOfMemory; storage.resizeWithinCapacity(4) catch unreachable; var set: Set = .{ .storage = storage, .n = 4 }; @field(set, \"view\") = set.storage.expose(); return set; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator) E!Answer { var storage = Bytes.init(gpa, 4) catch return error.OutOfMemory; errdefer storage.deinit(); const set: Set = .{ .storage = storage, .n = 4 }; return .{ .set = set }; }", pack.cleanup, true, 0);
    // The aggregate dropped: a finding.
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator) E!void { const storage = Bytes.init(gpa, 4) catch return error.OutOfMemory; const set: Set = .{ .storage = storage, .n = 4 }; _ = set.n; }", pack.cleanup, true, 1);
    // The owner named again after the move, or held by something other than a field: undecided.
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator) E!Set { var storage = Bytes.init(gpa, 4) catch return error.OutOfMemory; const set: Set = .{ .storage = storage, .n = storage.len() }; return set; }", pack.cleanup, false, 0);
    // An error a call maps is an error exit, which an `errdefer` covers.
    try expectJudged(head ++ "fn ready() bool { return true; }\npub fn f(gpa: std.mem.Allocator) E!Bytes { var out = Bytes.init(gpa, 4) catch return error.OutOfMemory; errdefer out.deinit(); while (true) { if (ready()) return out; if (ready()) return refused(); } }", pack.cleanup, true, 0);
}

test "a reservation consumed is discharged" {
    const head = "const std = @import(\"std\");\nconst Budget = @import(\"aegis\").bounded.Budget(usize);\n";
    try expectJudged(head ++ "pub fn f(b: *Budget, gpa: std.mem.Allocator) ![]u8 { var charge = b.reserve(4) catch return error.Limit; errdefer charge.release(); const m = try gpa.alloc(u8, 4); charge.consume(); return m; }", pack.cleanup, true, 0);
    // Kept past its success, the reservation leaves with the result: no claim either way.
    try expectJudged(head ++ "pub fn f(b: *Budget, gpa: std.mem.Allocator) ![]u8 { var charge = b.reserve(4) catch return error.Limit; errdefer charge.release(); const m = try gpa.alloc(u8, 4); return m; }", pack.cleanup, false, 0);
}

test "the private fields of staged payloads, machines, scopes, references, secondary maps and unparsed input" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\n";
    try expectJudged(head ++ "pub fn f(s: *Machine.At(.open, u32), r: *Machine.Runtime(u32)) void { _ = s.payload; _ = r.payload; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(s: aegis.scope.Table(Tag).Scope, r: aegis.scope.Ref(Tag, *u32)) void { _ = s.index; _ = r.pointer; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(m: *aegis.handle.SecondaryMap(aegis.handle.Index(Tag, u32), u8), u: aegis.input.Untrusted([]const u8)) void { _ = m.entries; _ = u.value; }", pack.access, true, 2);
    // The same names on other types are not these fields.
    try expectJudged(head ++ "const P = struct { payload: u8, state: u8, index: u8, pointer: u8, entries: u8, value: u8 };\npub fn f(p: P) void { _ = p.payload; _ = p.state; _ = p.index; _ = p.pointer; _ = p.entries; _ = p.value; }", pack.access, true, 0);
}

test "type information of a type that does not resolve is still type information" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\n";
    // `@typeInfo` of an unbound type parameter: its parts are `std.builtin.Type` values.
    try expectJudged(head ++ "pub fn F(comptime R: type) type { return @typeInfo(R).error_union.payload; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn F(comptime R: type) type { return switch (@typeInfo(R)) { .error_union => |eu| eu.payload, else => R }; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn F(comptime R: type) usize { return switch (@typeInfo(R)) { .@\"struct\" => |s| s.fields.len, .error_union, .optional => |x| @sizeOf(@TypeOf(x)), else => 0 }; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn F(comptime R: type) usize { const info = @typeInfo(R).@\"struct\"; return info.fields.len; }", pack.access, true, 0);
}

test "receivers through a guard's resolved type, builtins, destructuring, loop values and choices a build leaves out are decided" {
    const head = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst builtin = @import(\"builtin\");\nconst Shared = struct { closed: bool };\n";
    // A guard passed to a private `anytype` parameter is a guard by its resolved type.
    try expectJudged(head ++ "fn wait(held: anytype) void { _ = held.value().closed; }\npub fn f(g: *aegis.sync.BlockingGuarded(Shared), io: std.Io) void { var held = g.acquireUncancelable(io); defer held.release(); wait(&held); }", pack.access, true, 0);
    // A builtin's bytes, a string literal sliced, a tuple and an array destructured.
    try expectJudged(head ++ "pub fn f(err: anyerror) usize { return @intFromPtr(@errorName(err).ptr); }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f() usize { const in = \"abc\"; return @intFromPtr(in[0..2].ptr); }", pack.access, true, 0);
    try expectJudged(head ++ "const State = struct { n: u8 };\nfn split(b: []u8) struct { []u8, *State } { return .{ b, undefined }; }\npub fn f(b: []u8) usize { const read, const state = split(b); _ = state; return @intFromPtr(read.ptr); }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(a: [2][]u8) usize { const x, const y = a; _ = y; return @intFromPtr(x.ptr); }", pack.access, true, 0);
    // A type chosen per target: `noreturn` and alternatives without the member are other builds.
    try expectJudged(head ++ "const D = switch (builtin.os.tag) { .wasi => noreturn, .windows => struct { in: []const u8 }, else => struct { out: []u8 } };\nconst Op = union(enum) { d: D, e: u8 };\npub fn f(o: Op) usize { return switch (o) { .d => |d| @intFromPtr(d.in.ptr), .e => 0 }; }", pack.access, true, 0);
    try expectJudged(head ++ "const P = struct { index: u8 };\nconst S = struct { fixed: if (builtin.os.tag == .linux) ?[]P else void };\npub fn f(s: S) u8 { return s.fixed.?[0].index; }", pack.access, true, 0);
    // A loop used as a value gives its breaks, or its `else`.
    try expectJudged(head ++ "const P = struct { key: u8, value: []const u8 };\nconst E = struct { name: []const u8, params: []const P };\npub fn f(es: []const E, n: []const u8) usize { const entry = for (es) |e| { if (e.name.len == n.len) break e; } else null; if (entry) |e| { for (e.params) |p| return p.value.len; } return 0; }", pack.access, true, 0);
}

test "atomics, task contexts, ordered locks and counters are in the contract" {
    const head = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst O = aegis.sync.Order(&.{ .{ .name = \"a\" }, .{ .name = \"b\", .after = &.{0} } });\n";
    // An atomic's cell is private; a copy is a second cell.
    try expectJudged(head ++ "pub fn f(a: *aegis.sync.Atomic(u32)) void { _ = a.cell; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(a: aegis.sync.Atomic(u32)) u32 { const b = a; return a.load(.acquire) + b.load(.acquire); }", pack.copies, true, 1);
    // A task's context: private stack, a copy is a second context.
    try expectJudged(head ++ "pub fn f(c: *O.Context, i: *aegis.sync.InitContext) usize { return c.used + i.used; }", pack.access, true, 2);
    try expectJudged(head ++ "fn use(_: *const O.Context) void {}\npub fn f(c: O.Context) void { var d = c; _ = &d; use(&c); }", pack.copies, true, 1);
    // An ordered lock's base is private; its ordered acquisitions give guards released by `deinit`.
    try expectJudged(head ++ "const L = O.Ordered(aegis.sync.BlockingGuarded(u32), 0);\npub fn f(l: *L) void { _ = l.base; }", pack.access, true, 1);
    try expectJudged(head ++ "const L = O.Ordered(aegis.sync.BlockingGuarded(u32), 0);\npub fn f(l: *L, c: *O.Context, io: std.Io) void { var g = l.acquireOrderedUncancelable(io, c); g.value().* += 1; }", pack.cleanup, true, 1);
    try expectJudged(head ++ "const L = O.Ordered(aegis.sync.BlockingGuarded(u32), 0);\npub fn f(l: *L, c: *O.Context, io: std.Io) void { var g = l.acquireOrderedUncancelable(io, c); defer g.deinit(io); g.value().* += 1; }", pack.cleanup, true, 0);
    // A counter issues ids: a copy issues them twice.
    try expectJudged(head ++ "const C = aegis.id.Counter(struct {}, u32);\npub fn f(c: C) !void { var d = c; var e = c; _ = try d.next(); _ = try e.next(); }", pack.copies, true, 2);
}

test "A006 reports recursion untrusted input reaches without a depth bound" {
    const head = "const aegis = @import(\"aegis\");\nconst Text = aegis.input.Untrusted([]const u8);\n";
    // Each level of nesting is a stack frame the input chooses.
    try expectJudged(head ++ "pub fn read(text: Text) usize { return nest(text.readForParse()); }\nfn nest(bytes: []const u8) usize { if (bytes.len == 0 or bytes[0] != '[') return 0; return 1 + nest(bytes[1..]); }", pack.recursion, true, 1);
    // A position held against the input's length grows with it.
    try expectJudged(head ++ "pub fn read(text: Text) usize { return nest(text.readForParse(), 0); }\nfn nest(bytes: []const u8, at: usize) usize { if (at >= bytes.len) return 0; return 1 + nest(bytes, at + 1); }", pack.recursion, true, 1);
    // Through a parser the untrusted value is given, and across two functions.
    try expectJudged(head ++ "const Tree = struct { n: usize };\npub fn read(text: Text) error{Bad}!Tree { return text.parse({}, tree); }\nfn tree(_: void, bytes: []const u8) error{Bad}!Tree { return .{ .n = list(bytes) }; }\nfn list(bytes: []const u8) usize { return if (bytes.len == 0) 0 else item(bytes[1..]); }\nfn item(bytes: []const u8) usize { return list(bytes) + 1; }", pack.recursion, true, 1);
}

test "A006 accepts a depth the cycle moves and compares, and recursion no untrusted input reaches" {
    const head = "const aegis = @import(\"aegis\");\nconst Text = aegis.input.Untrusted([]const u8);\n";
    try expectJudged(head ++ "pub fn read(text: Text) error{TooDeep}!usize { return nest(text.readForParse(), 0); }\nfn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (depth > 64) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], depth + 1); }", pack.recursion, true, 0);
    try expectJudged(head ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn value(p: *Parser) error{TooDeep}!void { p.depth += 1; defer p.depth -= 1; if (p.depth > 64) return error.TooDeep; if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.value(); } };\npub fn read(text: Text) error{TooDeep}!void { var p: Parser = .{ .bytes = text.readForParse() }; try p.value(); }", pack.recursion, true, 0);
    // Through a helper that keeps the depth.
    try expectJudged(head ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn enter(p: *Parser) error{TooDeep}!void { p.depth += 1; if (p.depth > 64) return error.TooDeep; }\n fn value(p: *Parser) error{TooDeep}!void { try p.enter(); if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.value(); } };\npub fn read(text: Text) error{TooDeep}!void { var p: Parser = .{ .bytes = text.readForParse() }; try p.value(); }", pack.recursion, true, 0);
    try expectJudged(head ++ "pub fn count(bytes: []const u8) usize { return if (bytes.len == 0) 0 else 1 + count(bytes[1..]); }", pack.recursion, true, 0);
}

test "A001 finds public text built by a literal, by the type the literal takes from its place" {
    const head = "const err = @import(\"aegis\").err;\nconst Other = struct { bytes: []const u8 };\nfn show(s: err.PublicSource) void { _ = s; }\nfn take(o: Other) void { _ = o; }\n";
    // A declaration's written type, a call's parameter, a function's result, a typed literal,
    // a typed literal's field, `@as`, a made container's method.
    try expectJudged(head ++ "pub fn f(b: []const u8) void { const s: err.PublicSource = .{ .bytes = b }; _ = s; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(b: []const u8) void { show(.{ .bytes = b }); }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(b: []const u8) !err.PublicSource { if (b.len == 0) return error.Empty; return .{ .bytes = b }; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(b: []const u8) void { _ = err.PublicSource{ .bytes = b }; }", pack.access, true, 1);
    try expectJudged(head ++ "const Holder = struct { source: err.PublicSource };\npub fn f(b: []const u8) void { const h: Holder = .{ .source = .{ .bytes = b } }; _ = h; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(b: []const u8) void { _ = @as(err.PublicSource, .{ .bytes = b }); }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(b: []const u8) void { _ = err.PublicText(8).copy(.{ .bytes = b }); }", pack.access, true, 1);
    // `classify` is the way; a literal of another type with the same fields is not one, nor an
    // anonymous one.
    try expectJudged(head ++ "pub fn f(b: []const u8) void { show(err.PublicSource.classify(\"a reviewed name\", b)); }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(b: []const u8) void { take(.{ .bytes = b }); const o: Other = .{ .bytes = b }; _ = o; const a = .{ .bytes = b }; _ = a; }", pack.access, true, 0);
    // A literal naming other fields cannot be one; a place that does not resolve is undecided.
    try expectJudged(head ++ "pub fn f(b: []const u8, sink: anytype) void { sink.put(.{ .bytes = b, .more = 1 }); }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(b: []const u8, sink: anytype) void { sink.put(.{ .bytes = b }); }", pack.access, false, 0);
}

test "A001 reads a runtime machine's state as its backing field" {
    const head = "const aegis = @import(\"aegis\");\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\n";
    try expectJudged(head ++ "pub fn f(m: *Machine.Runtime(void)) S { return m.state; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(m: *Machine.Runtime(void)) S { return m.current(); }", pack.access, true, 0);
}

test "A001 reads a literal's place through a field default and optional and error-union results" {
    const head = "const err = @import(\"aegis\").err;\n";
    try expectJudged(head ++ "const Holder = struct { source: err.PublicSource = .{ .bytes = \"\" } };\npub fn f() Holder { return .{}; }", pack.access, true, 1);
    try expectJudged(head ++ "const R = struct { s: ?err.PublicSource = null };\npub fn f(b: []const u8) !R { return .{ .s = .{ .bytes = b } }; }", pack.access, true, 1);
    try expectJudged(head ++ "const Raw = struct { bytes: []const u8 };\nconst R = struct { s: ?Raw = null };\npub fn f(b: []const u8) !R { var r: R = .{}; r.s = .{ .bytes = b }; return .{ .s = .{ .bytes = b } }; }", pack.access, true, 0);
}

test "A001 reads a literal's place through generic slices and a handler held in a local" {
    const head = "const err = @import(\"aegis\").err;\nconst Raw = struct { bytes: []const u8 };\nfn keep(comptime T: type, items: []const T) void { _ = items; }\n";
    try expectJudged(head ++ "pub fn f(b: []const u8) void { keep(err.PublicSource, &.{.{ .bytes = b }}); }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(b: []const u8) void { keep(Raw, &.{.{ .bytes = b }}); }", pack.access, true, 0);
    try expectJudged(head ++ "const R = struct { s: ?Raw = null };\nconst Handlers = struct { make: ?*const fn () error{Bad}!R = null };\npub fn f(h: Handlers, b: []const u8) void { const g = h.make orelse return; var r = g() catch return; r.s = .{ .bytes = b }; }", pack.access, true, 0);
}

test "a made container's method result is read with the call's bindings through error unions and nested type functions" {
    const head = "const aegis = @import(\"aegis\");\nfn Line(comptime T: type) type { return struct { number: u32, value: T }; }\nfn Reader(comptime T: type) type { return struct { const Self = @This(); pub const Record = struct { value: T }; pub fn next(self: *Self) error{Bad}!?Line(T) { _ = self; return null; } pub fn record(self: *Self) ?Record { _ = self; return null; } }; }\nconst Plain = struct { data: u32 };\n";
    try expectJudged(head ++ "pub fn f(r: *Reader(Plain)) !void { while (try r.next()) |line| _ = line.value.data; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(r: *Reader(aegis.Guarded(u32))) !void { while (try r.next()) |line| _ = line.value.data; }", pack.access, true, 1);
    // A type the made container declares is made by the same call.
    try expectJudged(head ++ "pub fn f(r: *Reader(Plain)) void { if (r.record()) |rec| _ = rec.value.data; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(r: *Reader(aegis.Guarded(u32))) void { if (r.record()) |rec| _ = rec.value.data; }", pack.access, true, 1);
}

test "A001 refutes an unresolved receiver by the other members the file reads of the same expression" {
    // `p.name` beside `p.value`: no aegis type with a `value` field has a `name`.
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(access: anytype) void { for (access.pairs()) |p| { _ = p.name; _ = p.value; } }", pack.access, true, 0);
    // Without another member the receiver stays undecided.
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(access: anytype) void { for (access.pairs()) |p| _ = p.value; }", pack.access, false, 0);
}

test "A003 refutes an unresolved acquisition no aegis function can be by its arguments" {
    // Every aegis `read` takes at most an `Io`: two arguments are more than any takes. (With
    // std mapped, a type argument is refused too: `access.read([]const u8)`.)
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(access: anytype) !void { const text = try access.read([]const u8, 4); _ = text; }", pack.cleanup, true, 0);
    // An argument a `read` could take leaves it undecided.
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(access: anytype, io: anytype) !void { var g = try access.read(io); _ = &g; }", pack.cleanup, false, 0);
}

test "A002 reads operators and a tuple written in place" {
    // An operator gives no struct: a copy of its result copies no owner, nor an `if` one of whose branches is one.
    try expectJudged("pub fn f(comptime Int: type, a: Int, b: Int, g: fn () Int) void { const d = a - b; var x = if (a > b) g() + 1 else g(); const e = d; const y = x; _ = e; _ = y; _ = &x; }", pack.copies, true, 0);
    // An `inline for` over `.{ a, b }` takes each element in turn.
    try expectJudged("pub fn f() void { inline for (.{ @as(u8, 1), @as(u16, 2) }) |v| { var copy = v; _ = &copy; } }", pack.copies, true, 0);
}

test "a comptime condition settled on the path decides a receiver chosen by it" {
    const head = "const aegis = @import(\"aegis\");\nconst Direct = struct { data: u64, lock: bool };\n";
    // The direct side after `if (wrapped) return ...;`, in an `else`, or under `if (!wrapped)`.
    try expectJudged(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (wrapped) { var held = owner.acquire(); defer held.deinit(); return held.value().*; } return owner.data; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (wrapped) return 0 else return owner.data; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (!wrapped) { owner.lock = true; } return 0; }", pack.access, true, 0);
    // Through a type function of the condition: `Owner(wrapped)` read with what the path settles.
    try expectJudged(head ++ "fn Owner(comptime wrapped: bool) type { return if (wrapped) aegis.Guarded(u64) else Direct; }\npub fn f(comptime wrapped: bool, owner: *Owner(wrapped)) u64 { if (wrapped) return 0; return owner.data; }", pack.access, true, 0);
    // A container a type function makes with the condition, its field chosen by it.
    try expectJudged(head ++ "fn State(comptime wrapped: bool) type { return struct { m: if (wrapped) aegis.Guarded(u64) else Direct }; }\npub fn f(comptime wrapped: bool, s: *State(wrapped)) u64 { if (wrapped) return 0; const owner = &s.m; return owner.data; }", pack.access, true, 0);
    // On the wrapped side the same access is the aegis owner's backing field.
    try expectJudged(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (!wrapped) return 0; return owner.data; }", pack.access, true, 1);
}
