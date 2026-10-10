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
