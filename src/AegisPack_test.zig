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
/// What the pack writes at a public generic nothing the run binds (`Facts.unbound_generic`).
const unbound_generic = "unbound generic: judged at its consumers' bindings";
/// A rule's undecided sites in a run: the unbound notes, and every other.
const Undecided = struct { unbound: usize, other: usize };
fn undecidedOf(report: glint.Report, id: glint.Rule) Undecided {
    var found: Undecided = .{ .unbound = 0, .other = 0 };
    for (report.coverage) |entry| if (entry.rule == id) {
        if (std.mem.eql(u8, entry.detail, unbound_generic)) found.unbound += 1 else found.other += 1;
    };
    return found;
}
/// A run with `rule` gated is complete or not, with `findings` of it.
fn expectReport(report: glint.Report, rule: glint.Rule, complete: bool, findings: usize) !void {
    try std.testing.expectEqual(complete, report.complete);
    try std.testing.expectEqual(findings, count(report, rule));
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
        \\    var b = try Bytes.adopt(allocation[0..n], n);
        \\    defer b.deinit(gpa);
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
test "aegis pack accepts adopted gates, takes only the aegis escape and refuses glint-ignore" {
    var project = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }");
    defer project.deinit();
    var gated = try glint.runConfigured(std.testing.allocator, &project, .{ .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer gated.deinit();
    try std.testing.expect(gated.complete);
    try std.testing.expectEqual(glint.Config.Level.gate, gated.diagnostics[0].level);
    var invalid = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; } // glint-ignore: A001 -- test\n");
    defer invalid.deinit();
    var refused = try glint.runConfigured(std.testing.allocator, &invalid, config, .{ .project_rules = &pack.rules });
    defer refused.deinit();
    try std.testing.expect(!refused.complete);
    try std.testing.expectEqual(@as(usize, 1), refused.malformed.len); // safe: fixture count is representable.
    var valid = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; } // aegis: internal(A001): a fixture inspecting the representation to test erasure\n");
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
    var gated = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules, .files = &.{.{ .file = project.sources[0].id, .config = .{ .selections = &.{.{ .rule = pack.access, .level = .gate }} } }} });
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
        .{ pack.copies, "pub fn f(v: anytype) *const u32 { return v.expose(); }" },
        .{ pack.cleanup, "pub fn f(m: anytype) void { var v = m.T.init(1); _ = &v; }" },
        .{ pack.capacity, "pub fn f(T: type, bytes: []u8) void { _ = T.adopt(bytes, 0); }" },
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
    // `f` is a public generic nothing binds: undecided at its name alone, every copy in it decided.
    try std.testing.expectEqual(Undecided{ .unbound = 1, .other = 0 }, undecidedOf(report, pack.copies));
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
        \\    var b = try Bytes.adopt(allocation[0..n], n);
        \\    defer b.deinit(gpa);
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
    try std.testing.expectEqual(.parsed, plain_project.sources[0].file.status);
    try std.testing.expectEqual(.parsed, escaped_project.sources[0].file.status);
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
        try std.testing.expectEqual(.parsed, project.sources[0].file.status);
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
/// The flat aegis's roles, as aegis declares its own (`lint_rules`); `guard_member` names the
/// guard inside `Guarded`'s container.
fn flatRules(comptime guard_member: []const u8) []const u8 {
    return "pub const lint_rules = .{ .version = 1, .roles = .{\n" ++
        "    .{ .type = Secret, .role = .secret, .internal = .{.material} }, .{ .type = SecretBytes, .role = .bytes, .internal = .{ .allocation, .used_len } },\n" ++
        "    .{ .type = Guarded, .role = .guarded, .internal = .{ .lock, .data } }, .{ .type = .{ .generic = Guarded, .member = ." ++ guard_member ++ " }, .role = .guard, .internal = .{.owner} },\n" ++
        "    .{ .type = int.Checked, .role = .scalar }, .{ .type = int.Saturating, .role = .scalar }, .{ .type = int.Ranged, .role = .scalar },\n" ++
        "    .{ .type = id.Id, .role = .scalar }, .{ .type = id.NonZero, .role = .scalar }, .{ .type = id.Counter, .role = .issuer },\n" ++
        "    .{ .type = units.Count, .role = .scalar }, .{ .type = units.Bytes, .role = .scalar }, .{ .type = units.Bits, .role = .scalar }, .{ .type = units.Duration, .role = .scalar }, .{ .type = units.Instant, .role = .scalar },\n" ++
        "},\n    .pairs = .{.{ .type = .{ .generic = Guarded, .member = ." ++ guard_member ++ " }, .release = .{.deinit} }},\n};\n";
}
const flat_declared = flat_root_head ++ "pub const Guarded = @import(\"Guarded.zig\").Guarded;\n" ++ flat_root_tail;
const flat_root = flat_declared ++ "\n" ++ flatRules("Guard");
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
    \\pub fn adopt(allocation: []u8, used_len: usize) !@This() {
    \\    return .{ .allocation = allocation, .used_len = used_len };
    \\}
    \\pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void { _ = self; _ = gpa; }
;
const flat_int = scalarFile(&.{ "Checked", "Saturating", "Ranged" });
const flat_id = scalarFile(&.{ "Id", "NonZero", "Counter" });
const flat_units = scalarFile(&.{ "Count", "Bytes", "Bits", "Duration", "Instant" });
/// `build_scripts`: where set, a build script importing aegis's build script by aegis's name, as
/// the build runner names it, both stated compiled as this says.
const Flat = struct { root: []const u8 = flat_root, vault: []const u8 = "", library_selected: bool = false, build_scripts: ?P.Compilations = null };
fn flatFixture(bytes: []const u8, options: Flat) !P {
    const selected = options.library_selected;
    // aegis's sources, stated as its package as a caller states them; the vault is no package.
    const own = glint.AegisPack.package;
    var inputs = [_]P.Input{
        .{ .name = "consumer", .bytes = bytes },
        .{ .name = "root.zig", .bytes = options.root, .selected = selected, .package = own.name, .fingerprint = own.fingerprint },
        .{ .name = "Secret.zig", .bytes = flat_secret, .selected = selected, .package = own.name, .fingerprint = own.fingerprint },
        .{ .name = "Guarded.zig", .bytes = flat_guarded, .selected = selected, .package = own.name, .fingerprint = own.fingerprint },
        .{ .name = "SecretBytes.zig", .bytes = flat_bytes, .selected = selected, .package = own.name, .fingerprint = own.fingerprint },
        .{ .name = "int.zig", .bytes = flat_int, .selected = selected, .package = own.name, .fingerprint = own.fingerprint },
        .{ .name = "id.zig", .bytes = flat_id, .selected = selected, .package = own.name, .fingerprint = own.fingerprint },
        .{ .name = "units.zig", .bytes = flat_units, .selected = selected, .package = own.name, .fingerprint = own.fingerprint },
        .{ .name = "vault.zig", .bytes = options.vault, .selected = false },
        .{ .name = "build.zig", .bytes = "const aegis = @import(\"aegis\");\npub fn build() void {}\n", .compilations = options.build_scripts orelse .build },
        .{ .name = "aegis/build.zig", .bytes = "pub fn build() void {}\n", .selected = selected, .package = own.name, .fingerprint = own.fingerprint, .compilations = options.build_scripts orelse .build },
    };
    const imports = [_]P.Import{
        .{ .from = 9, .spelling = "aegis", .target = 10 },
        .{ .from = 0, .spelling = "aegis", .target = 1 },
        .{ .from = 0, .spelling = "vault", .target = 8 },
        .{ .from = 1, .spelling = "Secret.zig", .target = 2 },
        .{ .from = 1, .spelling = "Guarded.zig", .target = 3 },
        .{ .from = 1, .spelling = "SecretBytes.zig", .target = 4 },
        .{ .from = 1, .spelling = "int.zig", .target = 5 },
        .{ .from = 1, .spelling = "id.zig", .target = 6 },
        .{ .from = 1, .spelling = "units.zig", .target = 7 },
    };
    // Without build scripts, the last two inputs and the first import are left out.
    if (options.build_scripts == null) return P.init(std.testing.allocator, inputs[0..9], imports[1..], .{});
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
    \\    var b = try aegis.SecretBytes.adopt(allocation[0..n], n);
    \\    defer b.deinit(gpa);
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
test "A004 reads a scalar's raw integer by meaning, through every place it is put, and a scalar made by a cast" {
    const head = "const aegis = @import(\"aegis\");\nconst Index = aegis.id.Id(struct {}, u16);\nconst Box = struct { v: u16 };\n";
    // Read out by the language, by a name for `raw`, or through `@call`.
    try expectJudged(head ++ "pub fn f(i: Index) u16 { return @backingInt(i) + 1; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) u16 { return @intFromEnum(i) + 1; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) u16 { return Index.raw(i) + 1; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) u16 { return @call(.auto, Index.raw, .{i}) + 1; }", pack.scalar, true, 1);
    // Put in a field, a literal, an array, behind a pointer, an optional captured, a
    // destructuring and a vector's lanes.
    try expectJudged(head ++ "pub fn f(i: Index) u16 { var b: Box = .{ .v = 0 }; b.v = i.raw(); return b.v + 1; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) u16 { const b: Box = .{ .v = i.raw() }; return b.v + 1; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) u16 { const a = [_]u16{i.raw()}; return a[0] + 1; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) u16 { var v = i.raw(); const p = &v; return p.* + 1; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index, c: bool) u16 { const m: ?u16 = if (c) i.raw() else null; if (m) |v| return v + 1; return 0; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) u16 { const a, const b = .{ i.raw(), @as(u16, 0) }; return a + b; }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(i: Index) @Vector(2, u16) { const v: @Vector(2, u16) = @splat(i.raw()); return v + v; }", pack.scalar, true, 1);
    // A scalar made from an integer by a cast skips its checked construction.
    try expectJudged(head ++ "pub fn f(v: u16) Index { return @enumFromInt(v); }", pack.scalar, true, 1);
    try expectJudged(head ++ "pub fn f(v: u16) Index { return @fromBackingInt(v); }", pack.scalar, true, 1);
    // A made type's function called on the type or by a declaration literal types its
    // argument with the type's bindings.
    try expectJudged(head ++ "const Color = enum(u8) { red, _ };\nvar a: aegis.Atomic(Color) = .init(@fromBackingInt(0));\nvar b: aegis.Atomic(Index) = .init(@fromBackingInt(0));\nvar d: aegis.Atomic(Index) = aegis.Atomic(Index).init(@fromBackingInt(0));\npub fn f() void { _ = &a; _ = &b; _ = &d; }", pack.scalar, true, 2);
    // A cast by a generic parameter's type is each binding's: decided where it is bound.
    const generic = "fn Lib(comptime R: type) type { return struct { pub const Role = R; roles: []const R }; }\nfn role(library: anytype, n: u32) @TypeOf(library).Role { const Role = @TypeOf(library).Role; return @as(Role, @fromBackingInt(@as(u16, @intCast(n)))); }\nfn total(library: anytype) u32 { var sum: u32 = 0; for (library.roles) |r| sum += @intCast(@backingInt(r)); return sum; }\n";
    try expectUnbound(head ++ generic ++ "pub fn open(library: anytype, n: u32) @TypeOf(library).Role { return role(library, n); }", pack.scalar, 1, 0);
    try expectJudged(head ++ generic ++ "const Kind = enum(u16) { a, _ };\nconst lib: Lib(Kind) = .{ .roles = &.{} };\npub fn f() u32 { _ = role(lib, 1); return total(lib); }", pack.scalar, true, 0);
    try expectJudged(head ++ generic ++ "const lib: Lib(Index) = .{ .roles = &.{} };\npub fn f() u32 { _ = role(lib, 1); return total(lib); }", pack.scalar, true, 2);
    // An enum of the program's own, an array's length, a comparison of scalars: no raw integer.
    try expectJudged(head ++ "const Color = enum(u8) { red, green };\npub fn f(i: Index, x: u8) usize { const c: Color = @enumFromInt(x); const a = [_]u16{ i.raw(), 3 }; return a.len + @intFromEnum(c); }", pack.scalar, true, 0);
}

test "a standalone aegis namespace module is recognized" {
    var project = try fixture("const Id = @import(\"aegis\").id.Id; const Tag = struct {}; pub fn f() void { const v = Id(Tag, u32).fromRaw(1); _ = v.raw() + 2; }");
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
test "a role aegis declares that does not resolve is reported where aegis is imported, never a quiet gate" {
    // `Guarded`'s container declares no `Gaurd`: a misspelt member compiles (an enum literal), so
    // only the reader sees it.
    var project = try flatFixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }", .{ .root = comptime flat_declared ++ "\n" ++ flatRules("Gaurd") });
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
    try std.testing.expectEqualStrings("aegis's lint_rules at root.zig:9: a reference that does not resolve; the roles it declares are not all read in this file", detail.?);
}
test "an aegis that declares no lint_rules is undecided where it is imported, never plain" {
    var project = try flatFixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }", .{ .root = flat_declared });
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(!report.complete);
    var detail: ?[]const u8 = null;
    for (report.coverage) |entry| if (entry.rule != null) {
        detail = entry.detail;
    };
    try std.testing.expectEqualStrings("aegis's root root.zig declares no lint_rules; the roles of its types are not read in this file", detail.?);
}
test "a build script's import of aegis's name is aegis's build script, never its module: the program's aegis does not drift" {
    const consumer = "const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }";
    // What drifts with no build script at all: the fixture's root lacks members the contract
    // has grown since, each reported at the consumer's import.
    const alone = try driftReport(consumer, null);
    defer std.testing.allocator.free(alone);
    // Twins: the build runner's scripts drift nothing more, neither in the consumer nor in the
    // script; the same files stated as the program's are an `@import("aegis")` reaching a file
    // that publishes none of aegis, which is aegis drifted.
    for ([_]struct { P.Compilations, bool }{ .{ .build, true }, .{ .program, false } }) |case| {
        const found = try driftReport(consumer, case[0]);
        defer std.testing.allocator.free(found);
        try std.testing.expectEqual(case[1], std.mem.eql(u8, alone, found));
    }
}
/// The run's drift of aegis, each entry as "file: detail" on a line of its own, with
/// `build_scripts` as `Flat` has it.
fn driftReport(consumer: []const u8, build_scripts: ?P.Compilations) ![]const u8 {
    var project = try flatFixture(consumer, .{ .build_scripts = build_scripts });
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: the secret's backing access.
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    for (report.coverage) |entry| if (entry.rule != null) try out.writer.print("{s}: {s}\n", .{ project.at(entry.file).input.name, entry.detail });
    return out.toOwnedSlice();
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

/// A std of its reinterpreting reads: bytes of a value, a value or an integer out of bytes, an
/// enum out of an integer.
const reinterpreting_std = [_]aegis_sources.Extra{
    .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\npub const enums = @import(\"enums.zig\");" },
    .{ .name = "std/mem.zig", .bytes = "pub const Endian = enum { little, big };\npub fn asBytes(ptr: anytype) []const u8 { _ = ptr; return &.{}; }\npub fn toBytes(value: anytype) [8]u8 { _ = value; return undefined; }\npub fn readInt(comptime T: type, buffer: []const u8, endian: Endian) T { _ = buffer; _ = endian; return undefined; }\npub fn bytesToValue(comptime T: type, bytes: anytype) T { _ = bytes; return undefined; }" },
    .{ .name = "std/enums.zig", .bytes = "pub fn fromInt(comptime E: type, integer: anytype) ?E { _ = integer; return null; }" },
};
const reinterpreting_imports = [_]aegis_sources.ExtraImport{
    .{ .spelling = "std", .target = 0 },
    .{ .from = 0, .spelling = "mem.zig", .target = 1 },
    .{ .from = 0, .spelling = "enums.zig", .target = 2 },
};
fn expectReinterpreted(source: []const u8, findings: usize) !void {
    try expectWithBytes(source, pack.scalar, true, findings);
}
fn expectWithBytes(source: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try aegis_sources.projectWithSources(std.testing.allocator, source, &reinterpreting_std, &reinterpreting_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try expectReport(report, rule, complete, findings);
}

test "A001 reads a public source rewritten by a destructure, or through its whole address handed where it is written" {
    const head = "const std = @import(\"std\");\nconst err = @import(\"aegis\").err;\n";
    const made = "var p = err.PublicSource.classify(\"fixed label\", \"ok\");\n";
    try expectWithBytes(head ++ "pub fn f(secret: []const u8) err.PublicSource {\n" ++ made ++ "var n: usize = 0;\np.bytes, n = .{ secret, 1 };\n_ = &n;\nreturn p;\n}", pack.access, true, 1);
    try expectWithBytes(head ++ "pub fn f(secret: []const u8) err.PublicSource {\n" ++ made ++ "@memcpy(std.mem.asBytes(&p)[0..16], std.mem.asBytes(&secret)[0..16]);\nreturn p;\n}", pack.access, true, 1);
    // A function that may write through what it is given: undecided; one given a `*const`
    // pointer, and a `const` source's bytes, read only.
    try expectWithBytes(head ++ "fn fill(s: *err.PublicSource) void { _ = s; }\npub fn f() err.PublicSource {\n" ++ made ++ "fill(&p);\nreturn p;\n}", pack.access, false, 0);
    try expectWithBytes(head ++ "fn show(s: *const err.PublicSource) void { _ = s; }\npub fn f() err.PublicSource {\n" ++ made ++ "show(&p);\nreturn p;\n}", pack.access, true, 0);
    try expectWithBytes(head ++ "pub fn f() usize {\nconst p = err.PublicSource.classify(\"fixed label\", \"ok\");\nreturn std.mem.asBytes(&p).len;\n}", pack.access, true, 0);
}

test "A004 reads a scalar's bits reinterpreted by the language or std as its raw integer, and a scalar made so" {
    const head = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst Index = aegis.id.Id(struct {}, u16);\n";
    // Its bits read as an integer, or through a pointer to them, or as bytes read back.
    try expectReinterpreted(head ++ "pub fn f(i: Index) u16 { const v: u16 = @bitCast(i); return v + 1; }", 1);
    try expectReinterpreted(head ++ "pub fn f(i: Index) u16 { return @as(u16, @bitCast(i)) + 1; }", 1);
    try expectReinterpreted(head ++ "pub fn f(i: Index) u16 { const p: *const u16 = @ptrCast(&i); return p.* + 1; }", 1);
    try expectReinterpreted(head ++ "pub fn f(i: Index) u16 { return std.mem.readInt(u16, std.mem.asBytes(&i), .little) + 1; }", 1);
    // A scalar made of an integer's bits, out of bytes, or by std's enum reading.
    try expectReinterpreted(head ++ "pub fn f(v: u16) Index { return @bitCast(v); }", 1);
    try expectReinterpreted(head ++ "pub fn f(v: *const u16) Index { const p: *const Index = @ptrCast(v); return p.*; }", 1);
    try expectReinterpreted(head ++ "pub fn f(b: [2]u8) Index { return std.mem.bytesToValue(Index, &b); }", 1);
    try expectReinterpreted(head ++ "pub fn f(v: u16) !Index { return std.enums.fromInt(Index, v) orelse error.Bad; }", 1);
    // A number's bits, bytes and values out of them are no scalar's.
    try expectReinterpreted(head ++ "pub fn f(n: i16) u16 { const v: u16 = @bitCast(n); return v + 1; }", 0);
    try expectReinterpreted(head ++ "pub fn f(n: u16) u16 { return std.mem.readInt(u16, std.mem.asBytes(&n), .little) + 1; }", 0);
    try expectReinterpreted(head ++ "pub fn f(b: [2]u8) u16 { return std.mem.bytesToValue(u16, &b) + 1; }", 0);
    try expectReinterpreted(head ++ "const E = enum(u8) { a, b };\npub fn f(v: u8) ?E { return std.enums.fromInt(E, v); }", 0);
    // A generic that casts what it looks up by its type parameter makes a value of the type
    // it is bound to: a scalar's there, a plain struct's here. What it looks up is no value of
    // the parameter, though its place is computed from it.
    const lookup = "fn get(slots: []*anyopaque, comptime T: type) *T { const at = @sizeOf(T) % slots.len; return @ptrCast(@alignCast(slots[at])); }\n";
    try expectReinterpreted(head ++ lookup ++ "pub fn f(slots: []*anyopaque) *Index { return get(slots, Index); }", 1);
    try expectReinterpreted(head ++ lookup ++ "const Plain = struct { n: u32 };\npub fn f(slots: []*anyopaque) u32 { return get(slots, Plain).n; }", 0);
}

test "A004 reports a binding once, naming each of the generic's casts it makes a scalar's, however many paths and instances reach it" {
    const head = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst Index = aegis.id.Id(struct {}, u16);\n";
    // A generic casting by its type parameter at three places, one of them on two paths.
    const get = "fn get(slots: []*anyopaque, comptime T: type) *T {\n    if (slots.len == 1) return @ptrCast(@alignCast(slots[0]));\n    if (slots.len == 2) return @ptrCast(@alignCast(slots[1]));\n    return @ptrCast(@alignCast(slots[@sizeOf(T) % slots.len]));\n}\n";
    const outer = "fn outer(slots: []*anyopaque, comptime T: type) *T { return if (slots.len > 3) get(slots, T) else get(slots[1..], T); }\n";
    const rows = [_]struct { []const u8, usize }{
        // One binding: one finding, each cast named.
        .{ get ++ "pub fn f(slots: []*anyopaque) *Index { return get(slots, Index); }", 1 },
        // Bound through a second generic, on two of its paths, and so in two instances of it.
        .{ get ++ outer ++ "pub fn f(slots: []*anyopaque) *Index { return outer(slots, Index); }", 1 },
        // Twins: two bindings are two sites; a plain type binds none.
        .{ get ++ "pub fn f(slots: []*anyopaque) *Index { _ = get(slots, Index); return get(slots[1..], Index); }", 2 },
        .{ get ++ "const Plain = struct { n: u32 };\npub fn f(slots: []*anyopaque) u32 { return get(slots, Plain).n; }", 0 },
    };
    inline for (rows) |row| {
        var project = try aegis_sources.projectWithSources(std.testing.allocator, head ++ row[0], &reinterpreting_std, &reinterpreting_imports);
        defer project.deinit();
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.scalar, .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        if (count(report, pack.scalar) != row[1]) std.debug.print("{s}: {d} findings\n", .{ row[0], count(report, pack.scalar) });
        try std.testing.expectEqual(row[1], count(report, pack.scalar));
        for (report.diagnostics) |diagnostic| {
            try std.testing.expectEqual(@as(usize, 3), diagnostic.related.len); // safe: the generic's three casts.
            try std.testing.expect(std.mem.find(u8, diagnostic.message, "the integers") != null);
        }
    }
}

test "A004 strict: every operator, compound assignment and cast on a raw value, and one carried through a local or a branch" {
    const head = "const Index = @import(\"aegis\").id.Id(struct {}, u16);\nfn use(v: u16) void { _ = v; }\npub fn f(i: Index, maybe: ?u16, limit: u16) !u16 {\n    _ = .{ i, maybe, limit };\n";
    // Each unsafe probe computes with the raw value once; its safe twin hands it on or checks it.
    const cases = .{
        .{ "var n: u16 = 0; n += i.raw(); return n;", 1 },
        .{ "var n: u16 = 1; n <<= @intCast(i.raw()); return n;", 1 },
        .{ "return i.raw() >> 1;", 1 },
        .{ "return i.raw() & limit;", 1 },
        .{ "return i.raw() | limit;", 1 },
        .{ "return i.raw() ^ limit;", 1 },
        .{ "return i.raw() +| limit;", 1 },
        .{ "return ~i.raw();", 1 },
        .{ "return @bitCast(-%@as(i16, @bitCast(i.raw())));", 1 },
        .{ "return @intFromFloat(@as(f32, @floatFromInt(i.raw())));", 1 },
        .{ "return @divTrunc(i.raw(), 3);", 1 },
        .{ "return @min(i.raw(), limit);", 1 },
        .{ "return @byteSwap(i.raw());", 1 },
        .{ "const v = i.raw(); return v + 1;", 1 },
        .{ "const v = i.raw(); const w = v; return w * 2;", 1 },
        .{ "var v: u16 = 0; v = i.raw(); return if (v < limit) 1 else 0;", 1 },
        .{ "const v = if (limit > 0) i.raw() else 0; return v - 1;", 1 },
        .{ "const v = maybe orelse i.raw(); return v / 2;", 1 },
        .{ "const v = blk: { if (limit == 0) break :blk @as(u16, 0); break :blk i.raw(); }; return v % 7;", 1 },
        .{ "const v = @as(u16, i.raw()); return v + 1;", 1 },
        .{ "const v = switch (limit) { 0 => i.raw(), else => limit }; return v + 1;", 1 },
        // Safe twins: the raw value handed on, widened or converted by a checked call, and a
        // local that never held it.
        .{ "use(i.raw()); return 0;", 0 },
        .{ "const v = i.raw(); use(v); return v;", 0 },
        .{ "const wide = @as(u32, i.raw()); _ = wide; return 0;", 0 },
        .{ "return @import(\"std\").math.cast(u8, i.raw()) orelse error.Range;", 0 },
        .{ "const v = limit; return v + 1;", 0 },
        .{ "var v: u16 = limit; v += 1; return v;", 0 },
    };
    inline for (cases) |case| {
        var project = try fixture(head ++ "    " ++ case[0] ++ "\n}\n");
        defer project.deinit();
        const found = try scalarFindings(&project);
        if (found != case[1]) std.debug.print("{s}: {d} findings\n", .{ case[0], found });
        try std.testing.expectEqual(@as(usize, case[1]), found);
    }
}

/// One rule gated over `source`: whether the run decided every site, and how many findings.
fn judged(source: []const u8, rule: glint.Rule) !struct { complete: bool, findings: usize, undecided: Undecided } {
    var project = try fixture(source);
    defer project.deinit();
    try std.testing.expectEqual(.parsed, project.sources[0].file.status);
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    return .{ .complete = report.complete, .findings = count(report, rule), .undecided = undecidedOf(report, rule) };
}
fn expectJudged(source: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try fixture(source);
    defer project.deinit();
    try std.testing.expectEqual(.parsed, project.sources[0].file.status);
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try expectReport(report, rule, complete, findings);
}
/// `expectJudged` for a program whose public generic nothing binds, as the row means it to be:
/// `notes` unbound notes at generics' names (`unbound_generic`), every other site decided.
fn expectUnbound(source: []const u8, rule: glint.Rule, notes: usize, findings: usize) !void {
    const got = try judged(source, rule);
    try std.testing.expectEqual(notes, got.undecided.unbound);
    try std.testing.expectEqual(@as(usize, 0), got.undecided.other);
    try std.testing.expectEqual(findings, got.findings);
}
/// A std of the parts a rule names by declaration (std's allocator), beside aegis.
const std_fixture = [_]aegis_sources.Extra{
    .{ .name = "std/std.zig", .bytes = "pub const mem = @import(\"mem.zig\");\npub const Io = struct { pub const File = struct {}; pub const Dir = struct {}; pub const net = struct { pub const Stream = struct {}; pub const Server = struct {}; }; };\npub const process = struct { pub const Child = struct {}; };" },
    .{ .name = "std/mem.zig", .bytes = "pub const Allocator = @import(\"mem/Allocator.zig\");" },
    .{ .name = "std/mem/Allocator.zig", .bytes = "const Allocator = @This();\nptr: *anyopaque,\npub const Error = error{OutOfMemory};\npub fn alloc(a: Allocator, comptime T: type, n: usize) Error![]T { _ = a; _ = n; return &.{}; }\npub fn dupe(a: Allocator, comptime T: type, m: []const T) Error![]T { _ = a; _ = m; return &.{}; }\npub fn print(a: Allocator, comptime format: []const u8, args: anytype) Error![]u8 { _ = a; _ = args; return &.{}; }\npub fn free(a: Allocator, memory: anytype) void { _ = a; _ = memory; }" },
};
const std_fixture_imports = [_]aegis_sources.ExtraImport{
    .{ .spelling = "std", .target = 0 },
    .{ .from = 0, .spelling = "mem.zig", .target = 1 },
    .{ .from = 1, .spelling = "mem/Allocator.zig", .target = 2 },
};
fn expectJudgedStd(source: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try aegis_sources.projectWithSources(std.testing.allocator, source, &std_fixture, &std_fixture_imports);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try expectReport(report, rule, complete, findings);
}

test "receivers bound by captures are decided by what they bind" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst Plain = struct { data: u32, lock: u32 };\n";
    // A generic's result written over its `anytype` parameter (`@TypeOf(&slice[0])`), read
    // with the call's argument: an element of the slice it is given (airlock's slot lookup).
    const lookup = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst Index = aegis.handle.Index(Tag, u32);\n";
    try expectJudged(lookup ++ "const Slot = struct { index: Index };\npub fn find(all: []Slot, index: Index) ?*Slot { if (index.get(all)) |s| { if (s.index == index) return s; } else |_| {} return null; }", pack.access, true, 0);
    // A prong's capture of type information is that part of each type a choice gives
    // (shakedown's outcome of a simulated call, `@typeInfo(R)` per call's result type).
    try expectJudged("const aegis = @import(\"aegis\");\nfn width(comptime T: type) u64 { return @sizeOf(T); }\nfn outcome(comptime R: type, result: R) u64 { switch (@typeInfo(R)) { .error_union => |u| { const value = result catch return 0; _ = value; return width(u.payload); }, else => return 1 } }\npub fn f(a: error{A}!u32, b: error{B}!u8, c: bool) u64 { return outcome(@TypeOf(a), a) + outcome(@TypeOf(b), b) + outcome(bool, c); }", pack.access, true, 0);
    // The same where another `get` the program calls does not resolve, so its calls do not
    // settle the parameter: the call's own argument does.
    try expectJudged(lookup ++ "const ext = @import(\"missing\");\nconst Slot = struct { index: Index };\npub fn find(all: []Slot, index: Index) ?*Slot { if (index.get(all)) |s| { if (s.index == index) return s; } else |_| {} return null; }\npub fn other(t: ext.T) void { _ = t.get(1); }", pack.access, true, 0);
    // A switch prong's payload is the union field its item names.
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: G(u32) };\npub fn f(u: *const U) void { switch (u.*) { .a => |p| _ = p.data, .b => {} } }", pack.access, true, 0);
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: G(u32) };\npub fn f(u: *U) void { switch (u.*) { .a => {}, .b => |*g| _ = g.data } }", pack.access, true, 1);
    // Prong items whose payloads differ stay undecided.
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: G(u32) };\npub fn f(u: U) void { switch (u) { .a, .b => |x| _ = x.data } }", pack.access, false, 0);
    // An `inline` prong captures each field's payload in turn; `else`, those no other prong names.
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: Plain, c: G(u32) };\npub fn f(u: U) void { switch (u) { .c => {}, inline else => |x| _ = x.data } }", pack.access, true, 0);
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: Plain, c: G(u32) };\npub fn f(u: *U) void { switch (u.*) { .a => {}, inline else => |*x| _ = x.data } }", pack.access, true, 1);
    try expectJudged(head ++ "const U = union(enum) { a: Plain, b: G(u32), c };\npub fn f(u: U) void { switch (u) { inline .a, .c => |x| _ = x } }", pack.access, true, 0);
    // A `for` capture is its slice's element; a range's is a number.
    try expectJudged(head ++ "pub fn f(items: []Plain) void { for (items, 0..) |item, i| { _ = item.data; _ = i; } }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(items: []G(u32)) void { for (items) |*item| _ = item.data; }", pack.access, true, 1);
    // An array written in place, its element type named: a capture is that type.
    try expectJudged(head ++ "pub fn f() void { const Case = struct { state: u8, data: u8 }; for ([_]Case{ .{ .state = 0, .data = 1 } }) |case| { _ = case.state; _ = case.data; } }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(a: G(u32), b: G(u32)) void { for ([_]G(u32){ a, b }) |g| _ = g.data; }", pack.access, true, 1);
    // An `if` or `while` payload is its condition's optional or error-union payload.
    try expectJudged(head ++ "fn next() ?*Plain { return null; }\npub fn f() void { while (next()) |p| _ = p.lock; }", pack.access, true, 0);
    try expectJudged(head ++ "fn next() ?*G(u32) { return null; }\npub fn f() void { if (next()) |g| _ = g.lock; }", pack.access, true, 1);
    // A `while` payload is in scope in the loop's continue expression too.
    try expectJudged(head ++ "const Layer = struct { base: ?*const Layer, data: u32 };\npub fn f(first: ?*const Layer) u32 { var sum: u32 = 0; var at = first; while (at) |layer| : (at = layer.base) sum += layer.data; return sum; }", pack.access, true, 0);
    try expectJudged(head ++ "fn next() ?*G(u32) { return null; }\npub fn f() void { var n: u32 = 0; while (next()) |g| : (n += g.data) {} }", pack.access, true, 1);
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

test "A002 reads a copy from any place an owner is read through, an assignment's among them, and an address taken before a move or a borrow put in a local" {
    const head = "const S = @import(\"aegis\").Secret;\nconst H = struct { s: S(u32) };\n";
    // A field, what a pointer points at, an element and an optional's payload each copy the
    // owner they read; so does an assignment of one into storage.
    try expectJudged(head ++ "pub fn f(h: *H) void { const copy = h.s; _ = copy; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(p: *S(u32)) void { const copy = p.*; _ = copy; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(a: *[2]S(u32)) void { const copy = a[0]; _ = copy; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(o: *?S(u32)) void { const copy = o.*.?; _ = copy; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(h: *H) void { var s = S(u32).init(1); defer s.deinit(); h.s = s; }", pack.copies, true, 1);
    // A type named again holds no owner.
    try expectJudged(head ++ "pub fn f() void { const T = S(u32); const U = T; _ = U; }", pack.copies, true, 0);
    // A container's `const` is known as the program compiles and never changes: nothing can
    // release it or a copy of it. A container's `var` can be.
    try expectJudged(head ++ "const a = S(u32).init(1);\npub const b = a;", pack.copies, true, 0);
    try expectJudged(head ++ "var a = S(u32).init(1);\npub var b = a;", pack.copies, true, 1);
    // A borrow returned through a local, or in a literal's field, outlives its owner as one
    // returned in place does.
    try expectJudged(head ++ "pub fn f(s: *S(u32)) *const u32 { const v = s.expose(); return v; }", pack.copies, true, 1);
    try expectJudged(head ++ "const R = struct { v: *const u32 };\npub fn f(s: *S(u32)) R { return .{ .v = s.expose() }; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(s: *S(u32)) *const u32 { var v: *const u32 = undefined; v = s.expose(); return v; }", pack.copies, true, 1);
    // A local put back in itself is followed once (each hop of `head = head orelse x` doubled
    // the walk); a borrow in any of its values is still returned.
    try expectJudged(head ++ "pub fn f(s: *S(u32), xs: []const u32) ?*const u32 { var head: ?*const u32 = null; for (xs) |x| { if (x == 1) head = head orelse null; if (x == 2) head = head orelse null; if (x == 3) head = head orelse null; } _ = s; return head orelse null; }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(s: *S(u32), xs: []const u32) ?*const u32 { var head: ?*const u32 = null; for (xs) |x| { if (x == 1) head = head orelse null; if (x == 2) head = head orelse null; if (x == 3) head = head orelse s.expose(); } return head orelse null; }", pack.copies, true, 1);
    // A chain of locals past the depth the walk follows leaves the return undecided.
    var chain: std.ArrayList(u8) = .empty;
    defer chain.deinit(std.testing.allocator);
    try chain.appendSlice(std.testing.allocator, head ++ "pub fn f(s: *S(u32)) *const u32 { const v0 = s.expose();");
    for (1..300) |i| try chain.print(std.testing.allocator, " const v{d} = v{d};", .{ i, i - 1 });
    try chain.appendSlice(std.testing.allocator, " return v299; }");
    try expectJudged(chain.items, pack.copies, false, 0);
    // A reservation moved out of a local nothing reads again is moved; one whose address was
    // taken first is still reached through that address.
    const budget = "const bounded = @import(\"aegis\").bounded;\n";
    try expectJudged(budget ++ "pub fn f(b: *bounded.Budget(u32)) !void { const r = try b.reserve(1); var kept = r; defer kept.release(); }", pack.copies, true, 0);
    try expectJudged(budget ++ "pub fn f(b: *bounded.Budget(u32)) !void { var r = try b.reserve(1); const p = &r; var kept = r; defer kept.release(); _ = p; }", pack.copies, true, 1);
}

test "A002 reads a copy through a pointer a call returns, and an iterator a type function declared in another's container makes" {
    // A map's iterator is made by `Iterator(V)`, declared in `Map(K, V)`'s container: its
    // `next` gives a pointer to a stored owner, whatever path reads through it.
    const head =
        \\const S = @import("aegis").Secret;
        \\fn Map(comptime K: type, comptime V: type) type {
        \\    return struct {
        \\        keys: []K, values: []V,
        \\        pub const ValueIterator = Iterator(V);
        \\        fn Iterator(comptime T: type) type { return struct { items: []T, i: usize = 0, pub fn next(it: *@This()) ?*T { if (it.i == it.items.len) return null; it.i += 1; return &it.items[it.i - 1]; } }; }
        \\        pub fn valueIterator(m: *@This()) ValueIterator { return .{ .items = m.values }; }
        \\        pub fn getPtr(m: *@This(), i: usize) ?*V { return &m.values[i]; }
        \\    };
        \\}
        \\const Pair = struct { s: S(u32), n: u32 };
        \\fn make() Pair { return undefined; }
        \\
    ;
    try expectJudged(head ++ "pub fn f(m: *Map(u32, S(u32))) void { var it = m.valueIterator(); const copy = it.next().?.*; _ = copy; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(m: *Map(u32, S(u32))) void { var it = m.valueIterator(); const p = it.next(); const copy = p.?.*; _ = copy; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(m: *Map(u32, S(u32))) void { var it = m.valueIterator(); while (it.next()) |p| { const copy = p.*; _ = copy; } }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(m: *Map(u32, Pair)) void { const copy = m.getPtr(0).?.s; _ = copy; }", pack.copies, true, 1);
    // A number read through the same pointer, and an owner read off a value a call makes,
    // which no other holder shares, copy none.
    try expectJudged(head ++ "pub fn f(m: *Map(u32, Pair)) void { const n = m.getPtr(0).?.n; _ = n; }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(m: *Map(u32, u32)) void { var it = m.valueIterator(); while (it.next()) |p| { const n = p.*; _ = n; } }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f() void { const s = make().s; _ = s; }", pack.copies, true, 0);
    // A column of a list of rows (std's MultiArrayList): `items(field)` gives the row type's
    // field, `Elem` a constant of the made container read through the method's reading.
    const columns =
        \\fn Columns(comptime T: type) type {
        \\    return struct {
        \\        const Elem = switch (@typeInfo(T)) { .@"struct" => T, else => @compileError("rows") };
        \\        rows: []Elem,
        \\        pub const Slice = struct { base: []Elem, pub fn items(self: Slice, comptime field: []const u8) []FieldType(field) { _ = self; return undefined; } };
        \\        fn FieldType(comptime field: []const u8) type { return @FieldType(Elem, field); }
        \\        pub fn slice(c: *@This()) Slice { return .{ .base = c.rows }; }
        \\    };
        \\}
        \\
    ;
    try expectJudged(head ++ columns ++ "pub fn f(c: *Columns(Pair), i: usize) void { const copy = c.slice().items(\"s\")[i]; _ = copy; }", pack.copies, true, 1);
    try expectJudged(head ++ columns ++ "pub fn f(c: *Columns(Pair), i: usize) void { const n = c.slice().items(\"n\")[i]; _ = n; }", pack.copies, true, 0);
    // A branch a `@hasDecl` known as the program compiles rules out is not analysed.
    try expectJudged(head ++ "const A = struct { pub fn scan() void {} };\nconst B = struct {};\npub fn f(m: *Map(u32, Pair)) void { const p = m.getPtr(0).?; const x = if (comptime @hasDecl(A, \"scan\")) p.s else 0; const y = if (comptime @hasDecl(B, \"scan\")) p.s else 0; _ = .{ x, y }; }", pack.copies, true, 1);
    // A `while (true)` gives what its breaks give.
    try expectJudged(head ++ "pub fn f(m: *Map(u32, Pair)) void { var i: usize = 0; const p = while (true) { if (m.getPtr(i)) |found| break found; i += 1; }; const n = p.n; const copy = p.s; _ = .{ n, copy }; }", pack.copies, true, 1);
}

test "A002 follows a copy's value through every shape it is written in to the places it reads" {
    const head = "const S = @import(\"aegis\").Secret;\nconst H = struct { s: S(u32), t: S(u32) };\n";
    // Each branch, prong, `break`, operand and wrapper gives the copy one of its places.
    try expectJudged(head ++ "pub fn f(h: *H, c: bool) void { var copy = if (c) h.s else h.t; copy.deinit(); }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(h: *H, k: u8) void { var copy = switch (k) { 0 => h.s, else => h.t }; copy.deinit(); }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(h: *H) void { var copy = blk: { break :blk h.s; }; copy.deinit(); }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(h: *H) void { var copy = @as(S(u32), h.s); copy.deinit(); }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(o: *?S(u32), h: *H) void { var copy = o.* orelse h.s; copy.deinit(); }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(e: *anyerror!S(u32), h: *H) void { var copy = e.* catch h.s; copy.deinit(); }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(e: *anyerror!S(u32)) !void { var copy = try e.*; copy.deinit(); }", pack.copies, true, 1);
    // A literal's fields, typed or not, and a whole struct holding owners.
    try expectJudged(head ++ "pub fn f(h: *H, out: *H) void { out.* = .{ .s = h.s, .t = h.t }; }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(h: *H) H { const copy = H{ .s = h.s, .t = h.t }; return copy; }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(h: *H) void { var copy = h.*; copy.s.deinit(); }", pack.copies, true, 1);
    // A `return` copies what it reads, as a declaration does; the function's own local moves.
    try expectJudged(head ++ "pub fn f(h: *H) S(u32) { return h.s; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f() S(u32) { const s = S(u32).init(1); return s; }", pack.copies, true, 0);
    // A part of a generic's value, chosen or wrapped, is each binding's copy where only the
    // binding settles it; where its callers settle it (a private generic), each part is
    // decided where it is written.
    try expectUnbound(head ++ "pub fn f(h: anytype, c: bool) void { var copy = if (c) h.s else h.t; copy.deinit(); }", pack.copies, 1, 0);
    try expectJudged(head ++ "fn f(h: anytype, c: bool) void { var copy = if (c) h.s else h.t; copy.deinit(); }\npub fn g(h: *H) void { f(h, true); }", pack.copies, true, 2);
    try expectJudged(head ++ "const P = struct { s: u32, t: u32 };\nfn f(h: anytype, c: bool) void { var copy = if (c) h.s else h.t; _ = &copy; }\npub fn g(h: *P) void { f(h, true); }", pack.copies, true, 0);
    // Plain data written any of these ways is decided.
    try expectJudged(head ++ "pub fn f(c: bool, k: u8, n: u32) u32 { const a = if (c) n else 1; const b = switch (k) { 0 => a, else => blk: { break :blk @as(u32, 2); } }; return b; }", pack.copies, true, 0);
    // A value of a `comptime` function parameter's result type is that type's, whichever
    // function is passed.
    try expectJudged("fn keep(comptime T: type, comptime read: fn (u32) T) T { const shown = read(1); return shown; }\nfn one(x: u32) bool { return x == 1; }\npub fn f() bool { return keep(bool, one); }", pack.copies, true, 0);
}

test "A002 follows a returned or stored borrow through every shape that keeps it" {
    const head = "const S = @import(\"aegis\").Secret;\nconst R = struct { v: *const u32 };\n";
    // A prong, a labeled block, a cast, a slice, a local's field written later, an address of a
    // part read through it, a capture: each returns the borrow.
    try expectJudged(head ++ "pub fn f(s: *S(u32), k: u8) *const u32 { return switch (k) { 0 => s.expose(), else => s.expose() }; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(s: *S(u32)) *const u32 { return blk: { break :blk s.expose(); }; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(s: *S(u32)) *const u32 { return @as(*const u32, s.expose()); }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(s: *S(u32)) *const [4]u8 { return @ptrCast(s.expose()); }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(s: *S(u32)) []const u32 { return s.expose()[0..1]; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(s: *S(u32)) R { var r: R = undefined; r.v = s.expose(); return r; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(s: *S(u32)) *const u32 { const p = &s.expose().*; return p; }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(o: ?*S(u32)) ?*const u32 { if (o) |p| return p.expose(); return null; }", pack.copies, true, 1);
    // Stored where the caller reaches it, in a parameter's memory or a container's variable.
    try expectJudged(head ++ "pub fn f(s: *S(u32), out: **const u32) void { out.* = s.expose(); }", pack.copies, true, 1);
    try expectJudged(head ++ "var kept: ?*const u32 = null;\npub fn f(s: *S(u32)) void { kept = s.expose(); }", pack.copies, true, 1);
    // A call given the borrow may hand it back: undecided.
    try expectJudged(head ++ "fn id(p: *const u32) *const u32 { return p; }\npub fn f(s: *S(u32)) *const u32 { return id(s.expose()); }", pack.copies, false, 0);
    // The value read through it, a number a call or builtin makes of it, and a local's own
    // storage hold no borrow.
    try expectJudged(head ++ "fn sum(p: *const u32) u32 { return p.*; }\npub fn f(s: *S(u32), k: u8, out: *u32) u32 { var buf: u32 = 0; const p = &buf; p.* = s.expose().*; out.* = buf; const n = switch (k) { 0 => s.expose().*, else => sum(s.expose()) }; return n + @sizeOf(@TypeOf(s.expose())); }", pack.copies, true, 0);
}

test "A002 follows a generic's copy through any number of generics passing it on" {
    // Declared callee-last, each hop is found only after the one it calls: the search runs to
    // a fixed point, not a set number of rounds.
    var chain: std.ArrayList(u8) = .empty;
    defer chain.deinit(std.testing.allocator);
    try chain.appendSlice(std.testing.allocator, "const S = @import(\"aegis\").Secret;\npub fn use(s: S(u32)) void { h40(s); }\n");
    var i: usize = 40;
    while (i > 0) : (i -= 1) try chain.print(std.testing.allocator, "fn h{d}(x: anytype) void {{ h{d}(x); }}\n", .{ i, i - 1 });
    try chain.appendSlice(std.testing.allocator, "fn h0(x: anytype) void { var kept = x; kept.deinit(); }\n");
    try expectJudged(chain.items, pack.copies, true, 1);
}

test "A002 judges a generic's copy bound to a record of the program by the owners its fields hold" {
    // glint-c's n1e: copying the record copies the owner it holds by value; a field pointing
    // at the owner is an alias, which A002 leaves out.
    const head = "const S = @import(\"aegis\").Secret(u32);\nfn keep(comptime T: type, v: T) [2]T { return .{ v, v }; }\n";
    try expectJudged(head ++ "const H = struct { s: S, n: u32 };\npub fn f() void { const h: H = .{ .s = S.init(1), .n = 2 }; _ = keep(H, h); }", pack.copies, true, 1);
    try expectJudged(head ++ "const H = struct { inner: struct { s: S } };\npub fn f() void { const h: H = .{ .inner = .{ .s = S.init(1) } }; _ = keep(H, h); }", pack.copies, true, 1);
    try expectJudged(head ++ "const H = struct { s: *const S, n: u32 };\npub fn f(s: *const S) void { const h: H = .{ .s = s, .n = 2 }; _ = keep(H, h); }", pack.copies, true, 0);
}

/// How many sites `rule` leaves undecided over `source` because a call spelled as a copying
/// generic does not resolve.
fn unresolvedCopiers(source: []const u8, rule: glint.Rule) !usize {
    var project = try fixture(source);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var found: usize = 0;
    for (report.coverage) |entry| if (entry.rule != null and entry.rule.? == rule and std.mem.find(u8, entry.detail, "spelled as a generic that copies") != null) {
        found += 1;
    };
    return found;
}

test "A002, A003 and A004 leave a call to a copying generic that does not resolve undecided only where an argument may bind an owner" {
    // strand's `access.write(n)` on an anytype receiver: plain data, a cast number or a type of
    // plain data binds no owner, whatever `write` is; an owner, a type of one, or one cast to
    // its own type may.
    const head = "const S = @import(\"aegis\").Secret(u32);\nfn write(comptime T: type, value: T) [2]T { return .{ value, value }; }\npub fn use() void { _ = write(u32, 1); }\n";
    const plain = head ++ "pub fn f(n: u64, text: []const u8, access: anytype) void { _ = access.write(u64, n); _ = access.write([]const u8, text); _ = access.write(u8, @as(u8, 3)); _ = access.write([4]u8, .{ 1, 2, 3, 4 }); }";
    const owners = head ++ "pub fn f(owned: *S, access: anytype) void { _ = access.write(S, owned.*); _ = access.write(S, @as(S, owned.*)); }";
    for ([_]glint.Rule{ pack.copies, pack.cleanup, pack.scalar }) |rule| {
        try std.testing.expectEqual(@as(usize, 0), try unresolvedCopiers(plain, rule));
        try std.testing.expectEqual(@as(usize, 2), try unresolvedCopiers(owners, rule));
    }
}

test "A002 records for a generic's bindings only a copy whose value a binding settles" {
    // gantry's `scan(context: anytype, comptime read: anytype)` shapes, bound to a function
    // and a pointer: a `comptime` block's locals, what `@TypeOf` is given, a copy into a type
    // written apart from the parameters, and a place whose value resolves where it is written
    // are each decided where they are written, so a binding has nothing left to settle.
    const head = "const R = struct { specs: []const u8 = &.{} };\nfn extract(text: []const u8) !R { _ = text; return .{}; }\nconst Kind = enum { a, b };\nconst Spec = struct { kind: Kind };\n";
    const generic = "pub fn scan(context: anytype, comptime read: anytype, cached: []?R, i: usize) !void { comptime { const Inner = @typeInfo(@TypeOf(read(context))).error_union.error_set; _ = Inner; } const text = try read(context); const prior = if (cached.len > 0) cached[i] else null; const recovery = (prior orelse extract(text)) catch R{}; const specs = recovery.specs; _ = specs; const spec: Spec = .{ .kind = .a }; const kind: Kind = if (text.len == 0) .b else spec.kind; _ = kind; }\n";
    try expectJudged(head ++ generic ++ "fn reader(c: *u32) error{Bad}![]const u8 { _ = c; return \"\"; }\npub fn f(store: *u32, cached: []?R) !void { try scan(store, reader, cached, 0); }", pack.copies, true, 0);
    // `?R orelse f()` with `f` returning `!R` is an error union: `catch` unwraps it.
    try expectJudged(head ++ "pub fn f(cached: []?R, i: usize, text: []const u8) void { const prior = if (cached.len > 0) cached[i] else null; const recovery = (prior orelse extract(text)) catch R{}; const specs = recovery.specs; _ = specs; }", pack.copies, true, 0);
}

test "A002 clears a move only of the function's own local or a value captured in place, with no copy or address of it before" {
    const head = "const bounded = @import(\"aegis\").bounded;\nconst R = bounded.Budget(u32).Reservation;\nconst Hold = struct { maybe: ?R, list: [2]R };\n";
    // A capture of a place another still holds is a copy of it.
    try expectJudged(head ++ "pub fn f(h: *Hold) void { if (h.maybe) |r| { var kept = r; kept.release(); } h.maybe.?.release(); }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(h: *Hold) void { for (h.list) |r| { var kept = r; kept.release(); } h.list[0].release(); }", pack.copies, true, 1);
    // A copy before the move, by value to a call, into storage or twice, leaves two owners
    // (`keep` storing its own parameter is a copy as well).
    try expectJudged(head ++ "fn keep(r: R, into: *Hold) void { into.list[0] = r; }\npub fn f(b: *bounded.Budget(u32), h: *Hold) !void { const r = try b.reserve(1); keep(r, h); var kept = r; kept.release(); }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32), h: *Hold) !void { const r = try b.reserve(1); h.list[0] = r; var kept = r; kept.release(); }", pack.copies, true, 2);
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32)) !void { const r = try b.reserve(1); var one = r; var two = r; one.release(); two.release(); }", pack.copies, true, 2);
    // An address of a part taken before the move still reaches the old owner.
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32), out: **const u32) !void { var r = try b.reserve(1); out.* = &r.amount; var kept = r; kept.release(); }", pack.copies, true, 1);
    // A capture of a value made in place, and the last read of a local, move it.
    try expectJudged(head ++ "fn get(b: *bounded.Budget(u32)) ?R { return b.reserve(1) catch null; }\npub fn f(b: *bounded.Budget(u32)) void { if (get(b)) |r| { var kept = r; kept.release(); } }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(b: *bounded.Budget(u32)) !void { const r = try b.reserve(1); var kept = r; kept.release(); }", pack.copies, true, 0);
}

test "cleanup paths through branches, deferred releases and loops are decided" {
    const head = "const G = @import(\"aegis\").Guarded;\nfn ready() bool { return true; }\nfn hand(_: anytype) void {}\n";
    // Released in a branch that returns, and at the end of the fallthrough.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) { held.deinit(); return; } held.value().* += 1; held.deinit(); }", pack.cleanup, true, 0);
    // Deferred: every exit runs it, and a loop's own `break` does not leave the block.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) u32 { var held = g.acquire(); defer held.deinit(); while (true) { if (ready()) break; } for (0..3) |i| if (i == held.value().*) return 1; return 0; }", pack.cleanup, true, 0);
    // Released again after a deferred release: a witness.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); defer held.deinit(); held.deinit(); }", pack.cleanup, true, 1);
    // A return while held, a hand-off of its address to a function that may keep it held, a
    // release nested where the walk does not follow: undecided, never a claim.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) return; held.deinit(); }", pack.cleanup, false, 0);
    try expectJudged(head ++ "fn take(h: anytype) void { if (ready()) h.deinit(); }\npub fn f(g: *G(u32)) void { var held = g.acquire(); take(&held); }", pack.cleanup, false, 0);
    // Handed to a function that releases it on every path, the call releases it.
    try expectJudged(head ++ "fn take(h: anytype) void { h.deinit(); }\npub fn f(g: *G(u32)) void { var held = g.acquire(); take(&held); }", pack.cleanup, true, 0);
    // So does such a call deferred, of a guard a failing acquisition or an `orelse` gives
    // (cloak's `defer session.releaseWrite(&held)`); one that may keep it held stays undecided.
    try expectJudged(head ++ "fn take(h: anytype) void { h.deinit(); }\npub fn f(g: *G(u32)) void { var held = g.acquire(); defer take(&held); held.value().* += 1; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "fn take(h: anytype) void { h.deinit(); }\npub fn f(g: *G(u32)) void { var held = g.tryAcquire() orelse return; defer take(&held); held.value().* += 1; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "fn take(h: anytype) void { if (ready()) h.deinit(); }\npub fn f(g: *G(u32)) void { var held = g.acquire(); defer take(&held); }", pack.cleanup, false, 0);
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
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) u32 { var held = b.acquireUncancelable(io); const value = held.value(); while (true) { if (value.* != 0) { const v = value.*; held.deinit(io); return v; } else {} held.deinit(io); wait(); held = b.acquireUncancelable(io); } }", pack.cleanup, 1, 0);
    // Returned held from inside a loop that never ends otherwise: the caller's to release.
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) B.Guard { var held = b.acquireUncancelable(io); if (!ready()) return held; _ = held.value(); while (true) { if (ready()) return held; wait(); } }", pack.cleanup, 1, 0);
    // Its caller holds what it returns: released, or a finding.
    const give = "fn give(io: anytype, b: *B) B.Guard { var held = b.acquireUncancelable(io); _ = held.value(); return held; }\n";
    try expectUnbound(head ++ give ++ "pub fn f(io: anytype, b: *B) void { var held = give(io, b); defer held.deinit(io); }", pack.cleanup, 1, 0);
    try expectUnbound(head ++ give ++ "pub fn f(io: anytype, b: *B) void { var held = give(io, b); _ = held.value(); }", pack.cleanup, 1, 1);
    try expectJudged("const S = @import(\"aegis\").Secret;\nfn make() !S(u32) { return S(u32).init(1); }\npub fn f() !void { var s = try make(); _ = s.expose(); }", pack.cleanup, true, 1);
    // A pointer to an owner is no owner of the caller's.
    try expectJudged(head ++ "fn at(held: *B.Guard) *B.Guard { return held; }\npub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); defer held.deinit(io); const p = at(&held); _ = p; }", pack.cleanup, false, 0);
    // Released inside, left by `break`, released again after: decided, and a second release a witness.
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (ready()) { held.deinit(io); if (ready()) break; held = b.acquireUncancelable(io); } else held.deinit(io); }", pack.cleanup, 1, 0);
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (true) { if (ready()) { held.deinit(io); break; } } held.deinit(io); }", pack.cleanup, 1, 1);
    // Every way out of the loop held, and no release after it: a finding.
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (true) { if (ready()) break; _ = held.value(); wait(); } }", pack.cleanup, 1, 1);
    // Ways out in different states, or a body that comes back released: undecided.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); while (ready()) { if (ready()) { held.deinit(io); break; } } held.deinit(io); }", pack.cleanup, false, 0);
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); for (0..2) |_| { held.deinit(io); continue; } }", pack.cleanup, false, 0);
    // A release the body defers runs as each pass ends.
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) void { while (ready()) { var held = b.acquireUncancelable(io); defer held.deinit(io); if (ready()) continue; } }", pack.cleanup, 1, 0);
    // A jump to an outer loop of the walk is not followed.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); outer: while (ready()) { while (ready()) { if (ready()) continue :outer; } } held.deinit(io); }", pack.cleanup, false, 0);
    // A `break` of the walk's loop inside an expression is one of its ways out.
    try expectUnbound(head ++ "fn next() ?u32 { return null; }\npub fn f(io: anytype, b: *B) void { var held = b.acquireUncancelable(io); defer held.deinit(io); while (true) { const n = next() orelse break; _ = n; } }", pack.cleanup, 1, 0);
}

test "a guard's release handed off is a declared transfer" {
    const head = "const G = @import(\"aegis\").Guarded;\nfn ready() bool { return true; }\nfn park(handoff: anytype) void { handoff.release(); }\n";
    // Handed to a callback's context that releases it: decided, as a futex wait parks its task.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) { held.deinit(); return; } held.value().* += 1; var handoff = held.handOff(); park(&handoff); if (ready()) return; }", pack.cleanup, true, 0);
    // Handed off in one branch, released in the other.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); if (ready()) { var handoff = held.handOff(); park(&handoff); } else held.deinit(); }", pack.cleanup, true, 0);
    // A hand-off assigned to a local declared before is not followed, as no acquisition
    // assigned so is: undecided, never clear.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); var handoff: G(u32).Handoff = undefined; if (ready()) { handoff = held.handOff(); park(&handoff); } else held.deinit(); }", pack.cleanup, false, 0);
    // Released after the hand-off, or handed off after release: a witness each.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); var handoff = held.handOff(); park(&handoff); held.deinit(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); held.deinit(); var handoff = held.handOff(); park(&handoff); }", pack.cleanup, true, 1);
    // A hand-off thrown away is never released: the lock stays held, one finding at the discard.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); _ = held.handOff(); }", pack.cleanup, true, 1);
    // A hand-off is released exactly once: one kept and never released holds the lock.
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); var handoff = held.handOff(); _ = &handoff; }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(g: *G(u32)) void { var held = g.acquire(); var handoff = held.handOff(); handoff.release(); }", pack.cleanup, true, 0);
    // Returned, it is the caller's to release.
    try expectJudged(head ++ "fn give(g: *G(u32)) G(u32).Handoff { var held = g.acquire(); return held.handOff(); }\npub fn f(g: *G(u32)) void { var handoff = give(g); handoff.release(); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "fn give(g: *G(u32)) G(u32).Handoff { var held = g.acquire(); return held.handOff(); }\npub fn f(g: *G(u32)) void { var handoff = give(g); _ = &handoff; }", pack.cleanup, true, 1);
}

test "an owner a helper gives through an optional, a comptime choice or an array is owed" {
    const head = "const G = @import(\"aegis\").Guarded;\nconst RW = @import(\"aegis\").RwGuarded(u32);\n";
    try expectJudged(head ++ "fn lock(g: *G(u32), busy: bool) ?G(u32).Guard { if (busy) return null; return g.acquire(); }\npub fn f(g: *G(u32), busy: bool) void { var held = lock(g, busy) orelse return; held.value().* += 1; }", pack.cleanup, true, 1);
    try expectJudged(head ++ "fn lock(g: *G(u32), busy: bool) ?G(u32).Guard { if (busy) return null; return g.acquire(); }\npub fn f(g: *G(u32), busy: bool) void { var held = lock(g, busy) orelse return; defer held.deinit(); held.value().* += 1; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "fn both(a: *G(u32), b: *G(u32)) [2]G(u32).Guard { return .{ a.acquire(), b.acquire() }; }\npub fn f(a: *G(u32), b: *G(u32)) void { var held = both(a, b); held[0].value().* += 1; }", pack.cleanup, true, 1);
    try expectJudged(head ++ "fn both(a: *G(u32), b: *G(u32)) [2]G(u32).Guard { return .{ a.acquire(), b.acquire() }; }\npub fn f(a: *G(u32), b: *G(u32)) void { var held = both(a, b); defer for (&held) |*one| one.deinit(); held[0].value().* += 1; }", pack.cleanup, true, 0);
    // Each element an owner of its own, at its index: one released, the other leaks.
    try expectJudged(head ++ "fn both(a: *G(u32), b: *G(u32)) [2]G(u32).Guard { return .{ a.acquire(), b.acquire() }; }\npub fn f(a: *G(u32), b: *G(u32)) void { var held = both(a, b); held[0].deinit(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "fn both(a: *G(u32), b: *G(u32)) [2]G(u32).Guard { return .{ a.acquire(), b.acquire() }; }\npub fn f(a: *G(u32), b: *G(u32)) void { var held = both(a, b); held[0].deinit(); held[1].deinit(); }", pack.cleanup, true, 0);
    // An element at an index that is no literal may be either: undecided, never clear.
    try expectJudged(head ++ "fn both(a: *G(u32), b: *G(u32)) [2]G(u32).Guard { return .{ a.acquire(), b.acquire() }; }\npub fn f(a: *G(u32), b: *G(u32), i: usize) void { var held = both(a, b); held[i].deinit(); held[1].deinit(); }", pack.cleanup, false, 0);
    // A method on a comptime choice of receivers reads each receiver's bindings: plain data
    // either way (glint's own memo of a call's reading, Undefined.remembered).
    try expectJudged("fn Map(comptime V: type) type { return struct { v: V, pub fn get(m: *const @This()) ?V { return m.v; } }; }\nconst Needs = struct { mask: u64 };\nconst Memo = struct { found: Map(bool), needed: Map(Needs) };\nfn remembered(comptime T: type, memo: *Memo) ?T { const map = if (T == bool) &memo.found else &memo.needed; if (map.get()) |known| return known; return null; }\npub fn f(memo: *Memo) void { _ = remembered(bool, memo); _ = remembered(Needs, memo); }", pack.cleanup, true, 0);
}

test "a capture of what a call reaches copies it; a generic's returns and stores copy its parameter" {
    const head = "const G = @import(\"aegis\").Guarded;\n";
    const state = "const State = struct { guard: ?G(u32).Guard, guards: [2]G(u32).Guard, fn slot(s: *State) *?G(u32).Guard { return &s.guard; } fn held(s: *State) []G(u32).Guard { return s.guards[0..]; } };\n";
    try expectJudged(head ++ state ++ "pub fn f(s: *State) void { if (s.slot().*) |g| { var copy = g; copy.deinit(); } }", pack.copies, true, 1);
    try expectJudged(head ++ state ++ "pub fn f(s: *State) void { for (s.held()) |g| { var copy = g; copy.deinit(); } }", pack.copies, true, 1);
    try expectJudged(head ++ "pub fn f(l: *G(u32)) void { if (l.tryAcquire()) |g| { var copy = g; copy.deinit(); } }", pack.copies, true, 0);
    try expectJudged(head ++ "fn dup(x: anytype) [2]@TypeOf(x) { return .{ x, x }; }\npub fn f(l: *G(u32)) void { var both = dup(l.acquire()); both[0].deinit(); both[1].deinit(); }", pack.copies, true, 1);
    try expectJudged(head ++ "fn dup(x: anytype, out: *[2]@TypeOf(x)) void { out[0] = x; out[1] = x; }\npub fn f(l: *G(u32)) void { var both: [2]G(u32).Guard = undefined; dup(l.acquire(), &both); both[0].deinit(); }", pack.copies, true, 1);
    try expectJudged(head ++ "fn fill(x: anytype, out: []@TypeOf(x)) void { for (out) |*o| o.* = x; }\npub fn f(l: *G(u32)) void { var both: [2]G(u32).Guard = undefined; fill(l.acquire(), &both); both[0].deinit(); }", pack.copies, true, 1);
    // Written once and read nowhere else, the parameter is moved.
    try expectJudged(head ++ "fn one(x: anytype) [1]@TypeOf(x) { return .{x}; }\npub fn f(l: *G(u32)) void { var held = one(l.acquire()); held[0].deinit(); }", pack.copies, true, 0);
    try expectJudged(head ++ "fn put(x: anytype, out: *@TypeOf(x)) void { out.* = x; }\npub fn f(l: *G(u32)) void { var held: G(u32).Guard = undefined; put(l.acquire(), &held); held.deinit(); }", pack.copies, true, 0);
}

test "an owner stored where the function does not hold it is transferred" {
    const head = "const S = @import(\"aegis\").Secret;\nconst H = struct { s: ?S(u32) };\nfn ready() bool { return true; }\nfn g() !void {}\n";
    // Through a pointer, into a pointer's field, into a container's variable.
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) void { var s = S(u32).init(1); _ = s.expose(); slot.* = s; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(h: *H) void { const s = S(u32).init(1); if (h.s) |*old| old.deinit(); h.s = s; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "var kept: ?S(u32) = null;\npub fn f() void { const s = S(u32).init(1); kept = s; }", pack.cleanup, true, 0);
    // A field of a local value is the local's: not followed.
    try expectJudged(head ++ "pub fn f() void { var h: H = .{ .s = null }; const s = S(u32).init(1); h.s = s; _ = &h; }", pack.cleanup, false, 0);
    // Used after the store, or released again by an errdefer on an error exit after it.
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) void { var s = S(u32).init(1); slot.* = s; _ = s.expose(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) !void { var s = S(u32).init(1); errdefer s.deinit(); slot.* = s; try g(); }", pack.cleanup, true, 1);
    // A block of its own is walked statement by statement.
    try expectJudged(head ++ "pub fn f() void { var s = S(u32).init(1); { _ = s.expose(); s.deinit(); } }", pack.cleanup, true, 0);
}

fn expectJudgedWithDependency(source: []const u8, dependency: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try aegis_sources.projectWithDependency(std.testing.allocator, source, dependency);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try expectReport(report, rule, complete, findings);
}

/// `expectJudged` with `other` beside the program as `other.zig`, imported by its path and not
/// selected: a file of the program's own the run does not lint.
fn expectJudgedWithFile(source: []const u8, other: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try aegis_sources.projectWithSources(std.testing.allocator, source, &.{.{ .name = "other.zig", .bytes = other }}, &.{.{ .spelling = "other.zig", .target = 0 }});
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try expectReport(report, rule, complete, findings);
}

fn expectJudgedWithLib(source: []const u8, lib: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try aegis_sources.projectWith(std.testing.allocator, source, lib);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try expectReport(report, rule, complete, findings);
}

test "a public generic's parameters are each binding's, a consumer's among them; a private one's are its callers'" {
    // A raw integer read in a public generic, bound inside its package only to a plain type:
    // the read is each binding's, so the package alone is clean and a consumer's binding of an
    // aegis id is the finding, whether the package is linted with it or not. One no call
    // binds is given whatever binding is made: undecided where it is written.
    const lib = "pub fn bump(x: anytype) u32 { return x.raw() + 1; }\nconst Plain = struct { pub fn raw(_: Plain) u32 { return 1; } };\npub fn use() u32 { return bump(Plain{}); }\n";
    const consumer = "const lib = @import(\"lib\");\nconst Index = @import(\"aegis\").id.Id(struct {}, u32);\npub fn f() u32 { return lib.bump(Index.fromRaw(3)); }";
    try expectJudged(lib, pack.scalar, true, 0);
    try expectJudgedWithDependency(consumer, lib, pack.scalar, true, 1);
    try expectJudgedWithLib(consumer, lib, pack.scalar, true, 1);
    try expectJudged("const Index = @import(\"aegis\").id.Id(struct {}, u32);\n" ++ lib ++ "pub fn f() u32 { return bump(Index.fromRaw(3)); }", pack.scalar, true, 1);
    try expectJudged("pub fn bump(x: anytype) u32 { return x.raw() + 1; }\n", pack.scalar, false, 0);
    // A judgment of a generic's body not recorded per binding reads its parameters from its
    // callers only where they are all known: a private generic, not a public one, which a
    // consumer may call with anything.
    const head = "const G = @import(\"aegis\").Guarded;\nconst Plain = struct { data: u32 };\n";
    try expectJudged(head ++ "fn peek(g: anytype) u32 { return g.data; }\npub fn f(p: *Plain) u32 { return peek(p); }", pack.access, true, 0);
    try expectJudged(head ++ "fn peek(g: anytype) u32 { return g.data; }\npub fn f(p: *G(u32)) u32 { return peek(p); }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn peek(g: anytype) u32 { return g.data; }\npub fn f(p: *Plain) u32 { return peek(p); }", pack.access, false, 0);
}

test "an owner given by value to a function of the program's own, a dependency's or one in a file the run did not select, is undecided" {
    // The program is every loaded file but std's and aegis's: a function there is not walked
    // for what it does with the owner, and `keep` drops it.
    const head = "const S = @import(\"aegis\").Secret;\nconst lib = @import(\"lib\");\n";
    const map = "const S = @import(\"aegis\").Secret;\npub const Map = struct { pub fn put(self: *Map, value: S(u32)) !void { _ = self; _ = value; } pub fn keep(self: *Map, value: S(u32)) void { _ = self; _ = value; } };\n";
    try expectJudgedWithDependency(head ++ "pub fn f(m: *lib.Map) !void { var s = S(u32).init(1); errdefer s.deinit(); _ = s.expose(); try m.put(s); }", map, pack.cleanup, false, 0);
    try expectJudgedWithDependency(head ++ "pub fn f(m: *lib.Map) void { const s = S(u32).init(1); m.keep(s); }", map, pack.cleanup, false, 0);
    try expectJudgedWithDependency(head ++ "pub fn f(m: *lib.Map) !void { const s = S(u32).init(1); try m.put(s); }", map, pack.cleanup, false, 0);
    try expectJudgedWithDependency(head ++ "pub fn f(m: *lib.Map) void { var s = S(u32).init(1); m.keep(s); s.deinit(); }", map, pack.cleanup, false, 0);
    const keep = "pub fn keep(value: anytype) void { _ = value; }";
    try expectJudgedWithFile("const S = @import(\"aegis\").Secret;\nconst other = @import(\"other.zig\");\npub fn f() void { const s = S(u32).init(1); other.keep(s); }", keep, pack.cleanup, false, 0);
    try expectJudged("const S = @import(\"aegis\").Secret;\nfn keep(value: S(u32)) void { _ = value; }\npub fn f() void { const s = S(u32).init(1); keep(s); }", pack.cleanup, false, 0);
}

test "a switch's prongs are the owner's branches" {
    const head = "const S = @import(\"aegis\").Secret;\nfn read() error{ A, B }!usize { return 0; }\n";
    try expectJudged(head ++ "pub fn f(n: u8) void { var s = S(u32).init(1); switch (n) { 0 => s.deinit(), else => { _ = s.expose(); s.deinit(); } } }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(n: u8) void { var s = S(u32).init(1); switch (n) { 0 => s.deinit(), else => {} } }", pack.cleanup, false, 0);
    try expectJudged(head ++ "pub fn f(n: u8) void { var s = S(u32).init(1); switch (n) { 0 => s.deinit(), else => {} } s.deinit(); }", pack.cleanup, false, 0);
    // A handler's prongs: released and gone on one, the owner returned past the others.
    try expectJudged(head ++ "pub fn f() !?S(u32) { var s = S(u32).init(1); errdefer s.deinit(); const n = read() catch |err| switch (err) { error.A => 0, error.B => { s.deinit(); return null; } }; _ = n; return s; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(n: u8) void { var s = S(u32).init(1); switch (n) { 0 => s.deinit(), else => {} } _ = s.expose(); }", pack.cleanup, false, 0);
}

test "a flag set with the transfer tells the owner's paths apart" {
    const head = "const S = @import(\"aegis\").Secret;\nfn ready() bool { return true; }\n";
    // Stored on one path, flagged; the flag later chooses the release.
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) void { while (true) { var s = S(u32).init(1); var stored = false; { if (ready()) { slot.* = s; stored = true; } } if (stored) return; s.deinit(); } }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) void { var s = S(u32).init(1); var stored = true; if (ready()) slot.* = s else stored = false; if (!stored) s.deinit(); }", pack.cleanup, true, 0);
    // Released again on the flagged path: a witness.
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) void { var s = S(u32).init(1); var stored = false; if (ready()) { slot.* = s; stored = true; } if (stored) { s.deinit(); return; } s.deinit(); }", pack.cleanup, true, 1);
    // A flag written elsewhere, or declared outside the loop the branch runs in, tells nothing.
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) void { var s = S(u32).init(1); var stored = false; if (ready()) { slot.* = s; stored = true; } stored = ready(); if (!stored) s.deinit(); }", pack.cleanup, false, 0);
    try expectJudged(head ++ "pub fn f(slot: *S(u32)) void { var stored = false; while (ready()) { var s = S(u32).init(1); if (ready()) { slot.* = s; stored = true; } if (!stored) s.deinit(); } }", pack.cleanup, false, 0);
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
    // A method's own generic, called on a pointer the caller's generic was given. Public, it
    // is a consumer's to call too (a private type is reached through `go`'s parameter type):
    // its `anytype` holds what any binding gives, undecided here.
    const sched = "const Sched = struct { processors: []Plain, monitor: ?*Monitor };\nconst Monitor = struct {\n    samples: []u32,\n    ";
    const monitor = "fn run(m: *Monitor, s: anytype) void { for (s.processors, m.samples) |*p, *sample| { _ = m.look(s, p, sample); } }\n    fn look(m: *Monitor, s: anytype, p: anytype, sample: *u32) bool { _ = m; _ = s; _ = sample; _ = p.owner; return false; }\n};\npub fn go(s: *Sched) void { s.monitor.?.run(s); }";
    try expectJudged(head ++ sched ++ monitor, pack.access, true, 0);
    try expectJudged(head ++ sched ++ "pub " ++ monitor, pack.access, false, 0);
    // Taken other than by a call, its arguments are not all known: undecided.
    try expectJudged(head ++ "fn look(p: anytype) void { _ = p.owner; }\npub fn f() void { const taken = look; _ = taken; }", pack.access, false, 0);
}

test "a generic method std may call on a type the program hands it binds what std passes too: its parameters are not all the program's calls" {
    // std's `Map` calls its context's `look` with what it is given: an owner here, while the
    // program's own call passes a plain value. Undecided, not the program's binding alone.
    const lib = "pub fn Map(comptime C: type) type { return struct { ctx: C, pub fn put(self: *@This(), g: anytype) void { self.ctx.look(g); } }; }";
    const extra = std_fixture ++ [_]aegis_sources.Extra{.{ .name = "std/map.zig", .bytes = lib }};
    const imports = std_fixture_imports ++ [_]aegis_sources.ExtraImport{ .{ .from = 0, .spelling = "map.zig", .target = std_fixture.len }, .{ .spelling = "map.zig", .target = std_fixture.len } };
    const head = "const G = @import(\"aegis\").Guarded;\nconst Plain = struct { data: u32, owner: u32 };\nconst lib = @import(\"map.zig\");\n";
    for ([_]struct { []const u8, bool }{
        .{ "const Ctx = struct { pub fn look(_: Ctx, p: anytype) void { _ = p.data; } };\npub fn f(x: *Plain, g: *G(u32)) void { const c: Ctx = .{}; c.look(x); var m: lib.Map(Ctx) = .{ .ctx = c }; m.put(g); }", false },
        // A private method std cannot name: the program's calls are all of them.
        .{ "const Ctx = struct { fn look(_: Ctx, p: anytype) void { _ = p.data; } };\npub fn f(x: *Plain) void { const c: Ctx = .{}; c.look(x); }", true },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ head, case[0] });
        defer std.testing.allocator.free(source);
        var project = try aegis_sources.projectWithSources(std.testing.allocator, source, &extra, &imports);
        defer project.deinit();
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expectEqual(case[1], report.complete);
        try std.testing.expectEqual(@as(usize, 0), count(report, pack.access));
    }
}

test "a generic std may call on a context the program hands it is judged where it is written too: a cast or a copy of its value is not each program call's alone" {
    // std's `Map` calls its context's `hash` with what it is given, an aegis id or secret here,
    // no call of the program's showing it: the generic's own cast or copy stays undecided. A
    // private method std cannot name is bound by the program's calls only, each deciding it.
    const lib = "pub fn Map(comptime C: type) type { return struct { ctx: C, pub fn put(self: *@This(), key: anytype) void { _ = self.ctx.hash(key); } }; }";
    const extra = std_fixture ++ [_]aegis_sources.Extra{.{ .name = "std/map.zig", .bytes = lib }};
    const imports = std_fixture_imports ++ [_]aegis_sources.ExtraImport{ .{ .from = 0, .spelling = "map.zig", .target = std_fixture.len }, .{ .spelling = "map.zig", .target = std_fixture.len } };
    const head = "const aegis = @import(\"aegis\");\nconst Index = aegis.id.Id(struct {}, u32);\nconst S = aegis.Secret(u32);\nconst lib = @import(\"map.zig\");\n";
    for ([_]struct { glint.Rule, []const u8, bool }{
        .{ pack.scalar, "const Ctx = struct { pub fn hash(_: Ctx, key: anytype) u64 { return @intFromEnum(key) *% 31; } };\npub fn f(i: Index) void { var m: lib.Map(Ctx) = .{ .ctx = .{} }; m.put(i); }", false },
        .{ pack.scalar, "const Ctx = struct { fn hash(_: Ctx, key: anytype) u64 { return @intFromEnum(key) *% 31; } };\nconst E = enum(u32) { a };\npub fn f() u64 { const c: Ctx = .{}; return c.hash(E.a); }", true },
        .{ pack.copies, "const Ctx = struct { pub fn hash(_: Ctx, key: anytype) u64 { const copy = key; _ = copy; return 0; } };\npub fn f(s: S) void { var m: lib.Map(Ctx) = .{ .ctx = .{} }; m.put(s); }", false },
        .{ pack.copies, "const Ctx = struct { fn hash(_: Ctx, key: anytype) u64 { const copy = key; _ = copy; return 0; } };\npub fn f() u64 { const c: Ctx = .{}; return c.hash(@as(u32, 1)); }", true },
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ head, case[1] });
        defer std.testing.allocator.free(source);
        var project = try aegis_sources.projectWithSources(std.testing.allocator, source, &extra, &imports);
        defer project.deinit();
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = case[0], .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expectEqual(case[2], report.complete);
        try std.testing.expectEqual(@as(usize, 0), count(report, case[0]));
    }
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

test "a guard read in a condition before its release, and one waited on through its own wait, are decided" {
    const head = "const aegis = @import(\"aegis\");\n";
    // Read in an `if`'s condition and through its capture, then released.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *aegis.BlockingGuarded(?u32)) void { var held = b.acquireUncancelable(io); if (held.value().*) |v| { _ = v; } held.deinit(io); }", pack.cleanup, true, 0);
    // Acquired by `try`, its release deferred, waited on through its own `wait`, which holds it again on return.
    try expectJudged(head ++ "pub fn f(io: anytype, b: *aegis.BlockingGuarded(u32), c: *aegis.Condition) !void { var held = try b.acquire(io); defer held.deinit(io); while (held.value().* == 0) held.wait(c, io, .none) catch |err| switch (err) { error.Timeout => return, else => |e| return e }; }", pack.cleanup, true, 0);
    // Lent anywhere else, its release may move: undecided.
    try expectJudged(head ++ "var kept: ?*anyopaque = null;\nfn keep(g: anytype) void { kept = @ptrCast(g); }\npub fn f(io: anytype, b: *aegis.BlockingGuarded(u32)) !void { var held = try b.acquire(io); defer held.deinit(io); keep(&held); }", pack.cleanup, false, 0);
    // A guard never released is still a finding when it was read in a condition.
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *aegis.BlockingGuarded(?u32)) void { var held = b.acquireUncancelable(io); if (held.value().*) |v| { _ = v; } }", pack.cleanup, 1, 1);
}

test "a guard lent to the program's own function is a borrow when every path hands it back held" {
    const head = "const aegis = @import(\"aegis\");\nconst B = aegis.BlockingGuarded(u32);\n";
    const owner = "pub fn f(io: anytype, b: *B, c: *aegis.Condition) void { var held = b.acquireUncancelable(io); defer held.deinit(io); give(io, b, c, &held); }";
    // Released and held again, a wait on the way, a loan on to another that does the same.
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { held.deinit(io); held.* = b.acquireUncancelable(io); again(io, b, c, held); }\nfn again(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { while (held.value().* == 0) { held.deinit(io); held.* = b.acquireUncancelable(io); held.wait(c, io, .none) catch return; } }\n" ++ owner, pack.cleanup, true, 0);
    // A method of the program's own, through its receiver.
    try expectUnbound(head ++ "const S = struct { b: *B, fn give(s: *S, io: anytype, held: anytype) void { if (held.value().* == 0) return; held.deinit(io); held.* = s.b.acquireUncancelable(io); } };\npub fn f(io: anytype, s: *S) void { var held = s.b.acquireUncancelable(io); defer held.deinit(io); s.give(io, &held); }", pack.cleanup, 1, 0);
    // One path returns with it released: no loan, undecided.
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { _ = c; held.deinit(io); if (held == held) return; held.* = b.acquireUncancelable(io); }\n" ++ owner, pack.cleanup, false, 0);
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { _ = b; _ = c; held.deinit(io); }\n" ++ owner, pack.cleanup, false, 0);
    // A release it defers is no loan.
    try expectJudged(head ++ "fn give(io: anytype, b: *B, c: *aegis.Condition, held: anytype) void { _ = b; _ = c; defer held.deinit(io); }\n" ++ owner, pack.cleanup, false, 0);
}

test "an acquisition whose failure is caught is checked as one by `try` is" {
    const head = "const aegis = @import(\"aegis\");\nconst B = aegis.BlockingGuarded(u32);\n";
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquire(io) catch return; defer held.deinit(io); _ = held.value(); }", pack.cleanup, 1, 0);
    try expectUnbound(head ++ "pub fn f(io: anytype, b: *B) void { var held = b.acquire(io) catch return; _ = held.value(); }", pack.cleanup, 1, 1);
}

test "values initialized once and values one task owns keep their state behind their operations" {
    const head = "const aegis = @import(\"aegis\");\n";
    // A Once's and a Lazy's publication state, election lock, waiters and value.
    try expectJudged(head ++ "pub fn f(o: *aegis.Once(u32)) void { _ = o.state; _ = o.mutex; _ = o.changed; _ = o.data; }", pack.access, true, 4);
    try expectJudged(head ++ "pub fn f(l: *aegis.Lazy(u32)) void { _ = l.state; _ = l.data; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(l: *aegis.Lazy(u32)) ?aegis.Lazy(u32).Ref { return l.get(); }", pack.access, true, 0);
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

/// Reports, for each public constant of the checked file, the aegis role of what it names.
fn roleProbe(context: *glint.RuleContext) glint.RuleContext.Error!void {
    const tree = try context.project.syntax(try context.source());
    for (try context.project.declarations(try context.source())) |decl| {
        if (!decl.public) continue;
        const init = (tree.fullVarDecl(decl.node) orelse continue).ast.init_node.unwrap() orelse continue;
        const found = try context.role(pack.library, try context.facts.resolve(context.file, init));
        try context.at(role_probe_id, decl.token, if (found) |role| @tagName(role) else "none");
    }
}
const role_probe_id: glint.Rule = @fromBackingInt(1001); // safe: this test owns its validated extension identity.
const role_probe: glint.ProjectRule = .{ .definition = .{ .id = role_probe_id, .name = "AEGIS_ROLE_PROBE", .group = .family_policy, .purpose = "reports the aegis role of each public constant", .version = 1 }, .check = roleProbe };
// Every type the tables glint kept before aegis declared its roles named (AegisContract's, through
// glint 0.7), each as the pinned aegis names it; this list goes once aegis 0.3.0 has shipped its
// lint_rules once (glint-design §12).
const tabled =
    \\const aegis = @import("aegis");
    \\const Tag = struct {};
    \\const S = enum { open, done };
    \\const E = enum { finish };
    \\const M = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });
    \\const O = aegis.Order(&.{.{ .name = "a" }});
    \\pub const a = aegis.Secret;
    \\pub const b = aegis.SecretBytes;
    \\pub const c = aegis.SecretBytes.Writer;
    \\pub const d = aegis.Guarded;
    \\pub const e = aegis.BlockingGuarded;
    \\pub const f = aegis.RwGuarded;
    \\pub const g = aegis.SpinRwGuarded;
    \\pub const h = aegis.Condition;
    \\pub const i = aegis.Once;
    \\pub const j = aegis.Lazy;
    \\pub const k = aegis.Confined;
    \\pub const l = aegis.int.Checked;
    \\pub const m = aegis.int.Saturating;
    \\pub const n = aegis.int.Ranged;
    \\pub const o = aegis.id.Id;
    \\pub const p = aegis.id.NonZero;
    \\pub const q = aegis.id.Counter;
    \\pub const r = aegis.units.Count;
    \\pub const s = aegis.units.Bytes;
    \\pub const t = aegis.units.Bits;
    \\pub const u = aegis.units.Duration;
    \\pub const v = aegis.units.Instant;
    \\pub const w = aegis.secret.Choice;
    \\pub const x = aegis.Shared;
    \\pub const y = aegis.Atomic;
    \\pub const z = aegis.InitContext;
    \\pub const aa = O.Context;
    \\pub const ab = O.Ordered;
    \\pub const ac = aegis.bounded.Array;
    \\pub const ad = aegis.bounded.Ring;
    \\pub const ae = aegis.bounded.Buffer;
    \\pub const af = aegis.bounded.RingBuffer;
    \\pub const ag = aegis.bounded.Limit;
    \\pub const ah = aegis.bounded.Budget;
    \\pub const ai = aegis.bounded.Budget(u32).Reservation;
    \\pub const aj = aegis.own.Owned;
    \\pub const ak = aegis.own.OwnedIo;
    \\pub const al = aegis.own.MustUse;
    \\pub const am = aegis.handle.SlotPool;
    \\pub const an = aegis.handle.RunPool;
    \\pub const ao = aegis.handle.DenseSlotMap;
    \\pub const ap = aegis.handle.SecondaryMap;
    \\pub const aq = aegis.handle.Domain;
    \\pub const ar = aegis.handle.Index;
    \\pub const as = M.At;
    \\pub const at = M.Runtime;
    \\pub const au = aegis.scope.Table;
    \\pub const av = aegis.scope.Table(Tag).Scope;
    \\pub const aw = aegis.scope.Ref;
    \\pub const ax = aegis.input.Untrusted;
    \\pub const ay = aegis.err.PublicSource;
;
test "every type glint's tables named before aegis declared its roles has its role in aegis's lint_rules" {
    var project = try fixture(tabled);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = role_probe_id, .level = .gate }} }, .{ .project_rules = &.{role_probe} });
    defer report.deinit();
    try std.testing.expect(report.complete);
    const expected = [_][]const u8{ "secret", "bytes", "bytes_writer", "guarded", "guarded", "guarded", "guarded", "condition", "once", "once", "confined", "scalar", "scalar", "scalar", "scalar", "scalar", "issuer", "scalar", "scalar", "scalar", "scalar", "scalar", "choice", "shared", "atomic", "context", "context", "guarded", "inline_store", "inline_store", "buffer", "buffer", "limit", "budget", "reservation", "owned", "owned", "must_use", "slots", "slots", "slots", "slots", "issuer", "scalar", "stage", "machine", "table", "scope", "ref", "untrusted", "public_source" };
    try std.testing.expectEqual(expected.len, report.diagnostics.len);
    for (expected, report.diagnostics) |role, diagnostic| try std.testing.expectEqualStrings(role, diagnostic.message);
}

test "every published type after the guards is recognized where aegis is imported, with no drift" {
    try expectJudged(
        \\const aegis = @import("aegis");
        \\pub fn f(a: *aegis.bounded.Array(u8, 4), q: *aegis.bounded.Ring(u8, 4), b: *aegis.bounded.Buffer(u8), l: aegis.bounded.Limit(u32), budget: *aegis.bounded.Budget(u32)) void {
        \\    _ = a.len(); _ = q.len(); _ = b.len(); _ = l.exceeds(1); _ = budget.remaining();
        \\}
    , pack.access, true, 0);
}

test "an aegis with one name each for its ring and ring buffer, as 0.3 has, is recognized in full; one whose lint_rules names a ring it no longer declares drifts" {
    const gpa = std.testing.allocator;
    const pinned = aegis_sources.pinned("src/bounded.zig").?;
    try std.testing.expect(std.mem.find(u8, pinned, "pub const Queue") == null);
    const program = "const bounded = @import(\"aegis\").bounded;\npub fn f(r: *bounded.Ring(u8, 4), b: *bounded.RingBuffer(u8)) void { _ = r.head; _ = b.used; }";
    // Clean of drift: both backing reads found through the one name each.
    {
        var project = try aegis_sources.project(gpa, program);
        defer project.deinit();
        var report = try glint.runConfigured(gpa, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expect(report.complete);
        try std.testing.expectEqual(@as(usize, 2), count(report, pack.access));
    }
    // `Ring` itself gone: drift, where aegis is imported.
    const no_ring = try std.mem.replaceOwned(u8, gpa, pinned, "pub fn Ring(", "pub fn Circle(");
    defer gpa.free(no_ring);
    try std.testing.expect(!std.mem.eql(u8, no_ring, pinned));
    {
        var project = try aegis_sources.projectRevised(gpa, program, "src/bounded.zig", no_ring);
        defer project.deinit();
        var report = try glint.runConfigured(gpa, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expect(!report.complete);
        var drifted = false;
        for (report.coverage) |entry| if (entry.rule != null) {
            drifted = drifted or std.mem.eql(u8, entry.detail, "aegis's lint_rules at src/root.zig:116: a reference that does not resolve; the roles it declares are not all read in this file");
        };
        try std.testing.expect(drifted);
    }
}

test "an aegis whose pools are 0.3's SlotPool and RunPool, with no Pool or SlotMap, is recognized with no drift" {
    const gpa = std.testing.allocator;
    const pinned = aegis_sources.pinned("src/handle.zig").?;
    try std.testing.expect(std.mem.find(u8, pinned, "pub const SlotMap") == null and std.mem.find(u8, pinned, "pub const Pool ") == null);
    const program = "const handle = @import(\"aegis\").handle;\nconst Tag = struct {};\npub fn f(p: *handle.SlotPool(u8, Tag, .{}), r: *handle.RunPool(u8, Tag)) u32 { return p.count + p.used + r.end; }";
    var project = try aegis_sources.project(gpa, program);
    defer project.deinit();
    var report = try glint.runConfigured(gpa, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 3), count(report, pack.access));
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
    try expectJudgedStd(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator) !void { var s = try S.create(gpa, 1); defer s.release(); const copy = s; _ = copy; }", pack.copies, true, 1);
    // Owned: released, taken out or moved; left live it is a finding.
    try expectJudged(head ++ "pub fn f() void { var o = O.init(1); _ = o.borrow(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f() void { var o = O.init(1); defer o.deinit(); _ = o.borrow(); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(out: *u32) void { var o = O.init(1); o.take(out); }", pack.cleanup, true, 0);
    // MustUse: discharged by take or a reasoned acknowledgment; its deinit alone discharges nothing.
    try expectJudged(head ++ "pub fn f() void { var m = M.init(1); defer m.deinit(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f() void { var m = M.init(1); defer m.deinit(); m.acknowledge(\"the count is logged elsewhere\"); }", pack.cleanup, true, 0);
    // Its deinit after the discharge is the check that the discharge came.
    try expectJudged(head ++ "pub fn f(out: *u32) void { var m = M.init(1); m.take(out); m.deinit(); }", pack.cleanup, true, 0);
    // Shared: each handle, the created one and each retained one, is released.
    try expectJudgedStd(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator) !void { var s = try S.create(gpa, 1); defer s.release(); var other = s.retain(); _ = other.get(); }", pack.cleanup, true, 1);
    try expectJudgedStd(head ++ "pub fn f(gpa: @import(\"std\").mem.Allocator) !void { var s = try S.create(gpa, 1); defer s.release(); var other = s.retain(); defer other.release(); }", pack.cleanup, true, 0);
}

test "generational storage, staged payloads, machines, scopes, unparsed input and decisions keep their contracts" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\nconst Table = aegis.scope.Table(Tag);\n";
    // Slots behind keys; a copy of the map frees its storage twice.
    try expectJudged(head ++ "pub fn f(p: *aegis.handle.SlotPool(u32, Tag, .{}), m: *aegis.handle.SlotPool(u32, Tag, .{ .generation = u64 })) void { _ = p.slots; _ = m.free_head; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(region: aegis.Region, i: aegis.handle.Instance) !void { var m = try aegis.handle.SlotPool(u32, Tag, .{ .generation = u64 }).init(region, i); const copy = m; _ = copy; _ = &m; }", pack.copies, true, 1);
    try expectJudged(head ++ "fn none(_: *u32) void {}\npub fn f(region: aegis.Region, i: aegis.handle.Instance) !void { var m = try aegis.handle.SlotPool(u32, Tag, .{ .generation = u64 }).init(region, i); defer m.deinit(none); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(region: aegis.Region, i: aegis.handle.Instance) !void { var m = try aegis.handle.SlotPool(u32, Tag, .{ .generation = u64 }).init(region, i); _ = m.len(); }", pack.cleanup, true, 1);
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
    // An owner declared in a branch's or a loop's block body is checked there.
    try expectJudged("const G = @import(\"aegis\").Guarded;\npub fn f(g: *G(u32), c: bool) void { if (c) { var held = g.acquire(); _ = held.value(); } }", pack.cleanup, true, 1);
    try expectJudged("const G = @import(\"aegis\").Guarded;\npub fn f(g: *G(u32), xs: []const u8) void { for (xs) |_| { var held = g.acquire(); _ = held.value(); } }", pack.cleanup, true, 1);
    try expectJudged("const G = @import(\"aegis\").Guarded;\npub fn f(g: *G(u32), n: usize) void { var i: usize = 0; while (i < n) { var held = g.acquire(); _ = held.value(); i += 1; } }", pack.cleanup, true, 1);
    try expectJudged("const G = @import(\"aegis\").Guarded;\npub fn f(g: *G(u32), n: usize) void { var i: usize = 0; while (i < n) : (i += 1) { var held = g.acquire(); defer held.deinit(); _ = held.value(); } }", pack.cleanup, true, 0);
    // A member of it used after it ended, on every path there.
    try expectJudged(head ++ "pub fn f(t: *Table, n: *u32) !void { const s = try t.open(); s.end(); _ = s.ref(n); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(t: *Table, n: *u32, c: bool) !void { const s = try t.open(); if (c) { s.end(); } else { s.end(); } _ = s.ref(n); }", pack.cleanup, true, 1);
    // A deferred block that ends it once at its top level, the scope not named after.
    try expectJudged(head ++ "pub fn f(t: *Table, n: *u32) !void { const s = try t.open(); defer { s.end(); n.* += 1; } }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(t: *Table, n: *u32) !void { const s = try t.open(); errdefer { n.* += 1; s.end(); } try g(); s.end(); }\nfn g() !void {}", pack.cleanup, true, 0);
    // Ended only on one branch of the block, or named again after it, the block is not read.
    try expectJudged(head ++ "pub fn f(t: *Table, n: *u32) !void { const s = try t.open(); defer { if (n.* == 0) s.end(); } }", pack.cleanup, false, 0);
    try expectJudged(head ++ "pub fn f(t: *Table) !void { const s = try t.open(); defer { s.end(); _ = s.ref(t); } }", pack.cleanup, false, 0);
    try expectJudged(head ++ "pub fn f(t: *Table) !void { const s = try t.open(); defer s.end(); const copy = s; _ = copy; }", pack.copies, true, 0);
    // Unparsed input read past its parser; a decision read past its declassification.
    try expectJudged(head ++ "pub fn f(u: aegis.input.Untrusted([]const u8)) []const u8 { return u.readForParse(); }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(a: *const [4]u8, b: *const [4]u8) bool { const c = aegis.secret.equal(4, a, b); return c.bit == 1; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(a: *const [4]u8, b: *const [4]u8) bool { const c = aegis.secret.equal(4, a, b); const copy = c; return copy.declassify(\"fixture\"); }", pack.copies, true, 0);
}

test "a secret's writer borrows the owner it writes into; the owner keeps its release" {
    const head = "const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\n";
    // Read from a stream into the owner through its writer, then handed out: released on error.
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator) !Bytes { var text = try Bytes.init(gpa, 0); errdefer text.deinit(gpa); var w = Bytes.Writer.init(&text, gpa); try w.interface.writeAll(\"x\"); try w.interface.flush(); return text; }", pack.cleanup, true, 0);
    // The writer releases nothing: an owner left after it is still owed.
    try expectJudged(head ++ "pub fn f(gpa: std.mem.Allocator) !void { var text = try Bytes.init(gpa, 0); var w = Bytes.Writer.init(&text, gpa); w.interface.end = 0; }", pack.cleanup, true, 1);
}

test "an adoption of an allocation freed, changed or kept elsewhere before it is reported" {
    const head = "const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\n";
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); gpa.free(buffer); return Bytes.adopt(buffer, n); }", pack.capacity, true, 1);
    // A function it is handed to, whatever it returns: one that keeps it, frees it, or frees
    // it by its pointer; and its address kept as a number.
    try expectJudgedStd(head ++ "var kept: []u8 = &.{};\nfn stash(p: []u8) void { kept = p; }\npub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); stash(buffer); return Bytes.adopt(buffer, n); }", pack.capacity, true, 1);
    try expectJudgedStd(head ++ "fn drop(gpa: std.mem.Allocator, p: []u8) void { gpa.free(p); }\npub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); drop(gpa, buffer); return Bytes.adopt(buffer, n); }", pack.capacity, true, 1);
    try expectJudgedStd(head ++ "fn release(gpa: std.mem.Allocator, p: [*]u8, len: usize) usize { gpa.free(p[0..len]); return len; }\npub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); _ = release(gpa, buffer.ptr, buffer.len); return Bytes.adopt(buffer, n); }", pack.capacity, true, 1);
    try expectJudgedStd(head ++ "var where: usize = 0;\npub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); where = @intFromPtr(buffer.ptr); return Bytes.adopt(buffer, n); }", pack.capacity, true, 1);
    // One that only fills it and gives back nothing, and its address compared, leave it whole.
    try expectJudgedStd(head ++ "fn fill(p: []u8) void { @memset(p, 0); }\npub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); fill(buffer); return Bytes.adopt(buffer, n); }", pack.capacity, true, 0);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); if (@intFromPtr(buffer.ptr) == 0) unreachable; return Bytes.adopt(buffer, n); }", pack.capacity, true, 0);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { var buffer = try gpa.alloc(u8, n); buffer.len = 1; return Bytes.adopt(buffer, 1); }", pack.capacity, true, 1);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { var buffer = try gpa.alloc(u8, n); buffer.ptr += 1; return Bytes.adopt(buffer, n - 1); }", pack.capacity, true, 1);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { var buffer = try gpa.alloc(u8, n); buffer = buffer[1..]; return Bytes.adopt(buffer, n - 1); }", pack.capacity, true, 1);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize, keep: *[]u8) !Bytes { const buffer = try gpa.alloc(u8, n); keep.* = buffer; return Bytes.adopt(buffer, n); }", pack.capacity, true, 1);
    // Two owners of one allocation: the second adoption is reported, the first is not handed
    // over alone.
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) ![2]Bytes { const buffer = try gpa.alloc(u8, n); return .{ try Bytes.adopt(buffer, n), try Bytes.adopt(buffer, n) }; }", pack.capacity, false, 1);
    // Its elements written and its length read leave it whole.
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); if (buffer.len != n) return error.Short; buffer[0] = 1; @memset(buffer[1..], 0); return Bytes.adopt(buffer, n); }", pack.capacity, true, 0);
}

test "an adoption of a whole byte allocation, handed over alone, is decided" {
    const head = "const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\n";
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); @memset(buffer, 0); return Bytes.adopt(buffer, n); }", pack.capacity, true, 0);
    try expectJudgedStd(head ++ "const S = struct { gpa: std.mem.Allocator };\npub fn f(s: *S, n: usize) !Bytes { const buffer = s.gpa.alloc(u8, n) catch return error.OutOfMemory; return Bytes.adopt(buffer, n); }", pack.capacity, true, 0);
    // The owner is unmanaged: which allocator made the allocation is the caller's to give its
    // deinit, so another allocator's allocation is decided at the adoption too.
    try expectJudgedStd(head ++ "pub fn f(other: std.mem.Allocator, n: usize) !Bytes { const buffer = try other.alloc(u8, n); return Bytes.adopt(buffer, n); }", pack.capacity, true, 0);
    // A pending errdefer, a later use or an element wider than a byte stay review sites.
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); errdefer gpa.free(buffer); const b = try Bytes.adopt(buffer, n); return b; }", pack.capacity, false, 0);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); const b = try Bytes.adopt(buffer, n); buffer[0] = 1; return b; }", pack.capacity, false, 0);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator, n: usize) !Bytes { const buffer = try gpa.alloc(u8, n); return Bytes.adopt(buffer[0..n], n); }", pack.capacity, false, 1);
    // std's allocator by its declaration: a pool of the program's own with an `alloc` of the
    // same shape hands out a part of its buffer, no whole allocation.
    try expectJudgedStd(head ++ "const Pool = struct { buffer: [64]u8 = undefined, used: usize = 0, fn alloc(p: *Pool, comptime T: type, n: usize) ![]T { const part = p.buffer[p.used..][0..n]; p.used += n; return part; } };\npub fn f(pool: *Pool, n: usize) !Bytes { const buffer = try pool.alloc(u8, n); return Bytes.adopt(buffer, n); }", pack.capacity, false, 0);
}

test "an adoption of a private function's parameter is decided by every call's argument, through what a function returns" {
    const head = "const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\nfn adopted(bytes: []u8) Bytes { return Bytes.adopt(bytes, bytes.len) catch unreachable; }\n";
    const session = "const S = struct {\n    gpa: std.mem.Allocator,\n    fn ask(s: *S, quiet: bool) !?[]u8 { if (quiet) { if (try s.helper()) |answer| return answer; return null; } const copy = try s.gpa.dupe(u8, \"x\"); return copy; }\n    fn helper(s: *S) !?[]u8 { if (s.gpa.vtable == undefined) return error.Unavailable; return try s.gpa.dupe(u8, \"y\"); }\n};\n";
    // Each argument a whole allocation: printed, duplicated, allocated into a local used only
    // before, and returned by a method on every path that gives one.
    try expectJudgedStd(head ++ session ++ "pub fn f(s: *S, n: usize) !void { var a = adopted(s.gpa.print(\"{d}\", .{n}) catch return error.OutOfMemory); a.deinit(s.gpa); const buffer = try s.gpa.alloc(u8, n); @memset(buffer, 0); var b = adopted(buffer); b.deinit(s.gpa); var c = adopted(try s.ask(true) orelse return); c.deinit(s.gpa); }", pack.capacity, true, 0);
    // A public function, a returned local a `defer` frees, or a local read after the call stay
    // review sites.
    try expectJudgedStd("const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\npub fn adopted(bytes: []u8) Bytes { return Bytes.adopt(bytes, bytes.len) catch unreachable; }\npub fn f(gpa: std.mem.Allocator) !void { var a = adopted(try gpa.dupe(u8, \"x\")); a.deinit(gpa); }", pack.capacity, false, 0);
    try expectJudgedStd(head ++ "fn made(gpa: std.mem.Allocator) ![]u8 { const copy = try gpa.dupe(u8, \"x\"); defer gpa.free(copy); return copy; }\npub fn f(gpa: std.mem.Allocator) !void { var a = adopted(try made(gpa)); a.deinit(gpa); }", pack.capacity, false, 0);
    try expectJudgedStd(head ++ "pub fn f(gpa: std.mem.Allocator) !void { const buffer = try gpa.dupe(u8, \"x\"); var a = adopted(buffer); a.deinit(gpa); buffer[0] = 0; }", pack.capacity, false, 0);
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
    try expectUnbound(head ++ "const Opt = struct { index: usize };\nconst Info = struct { options: []const Opt, positionals: []const Opt };\npub fn f(comptime info: Info) usize { var n: usize = 0; inline for (info.options ++ info.positionals) |o| n += o.index; return n; }", pack.access, 1, 0);
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
    try expectUnbound(head ++ "pub fn g(o: anytype) void { const s = &o.request; _ = &s.run; }", pack.access, 1, 0);
    // A member written to, or read as a number, is a field.
    try expectUnbound(head ++ "pub fn g(o: anytype, n: u32) void { o.run = n; if (o.run > 1) o.run -= 1; }", pack.access, 1, 0);
    // An `anytype` parameter dereferenced is a pointer: its member passed on is a field.
    try expectUnbound(head ++ "fn take(_: anytype) void {}\npub fn g(o: anytype) void { const T = @TypeOf(o.*); _ = T; take(o.run); }", pack.access, 1, 0);
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
    try expectJudgedStd(head ++ "pub fn f(b: *Budget, gpa: std.mem.Allocator) ![]u8 { var charge = b.reserve(4) catch return error.Limit; errdefer charge.release(); const m = try gpa.alloc(u8, 4); charge.consume(); return m; }", pack.cleanup, true, 0);
    // Kept past its success, the reservation leaves with the result: no claim either way.
    try expectJudgedStd(head ++ "pub fn f(b: *Budget, gpa: std.mem.Allocator) ![]u8 { var charge = b.reserve(4) catch return error.Limit; errdefer charge.release(); const m = try gpa.alloc(u8, 4); return m; }", pack.cleanup, false, 0);
}

test "the private fields of staged payloads, machines, scopes, references, secondary maps and unparsed input" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\n";
    try expectJudged(head ++ "pub fn f(s: *Machine.At(.open, u32), r: *Machine.Runtime(u32)) void { _ = s.payload; _ = r.payload; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(s: aegis.scope.Table(Tag).Scope, r: aegis.scope.Ref(Tag, *u32)) void { _ = s.index; _ = r.pointer; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(m: *aegis.handle.SecondaryMap(aegis.handle.SlotPool(u32, Tag, .{ .generation = u64 }), u8), u: aegis.input.Untrusted([]const u8)) void { _ = m.free_head; _ = u.value; }", pack.access, true, 2);
    // The same names on other types are not these fields.
    try expectJudged(head ++ "const P = struct { payload: u8, state: u8, index: u8, pointer: u8, entries: u8, value: u8 };\npub fn f(p: P) void { _ = p.payload; _ = p.state; _ = p.index; _ = p.pointer; _ = p.entries; _ = p.value; }", pack.access, true, 0);
}

test "type information of a type that does not resolve is still type information" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\n";
    // `@typeInfo` of an unbound type parameter: its parts are `std.builtin.Type` values.
    try expectUnbound(head ++ "pub fn F(comptime R: type) type { return @typeInfo(R).error_union.payload; }", pack.access, 1, 0);
    try expectUnbound(head ++ "pub fn F(comptime R: type) type { return switch (@typeInfo(R)) { .error_union => |eu| eu.payload, else => R }; }", pack.access, 1, 0);
    try expectUnbound(head ++ "pub fn F(comptime R: type) usize { return switch (@typeInfo(R)) { .@\"struct\" => |s| s.fields.len, .error_union, .optional => |x| @sizeOf(@TypeOf(x)), else => 0 }; }", pack.access, 1, 0);
    try expectUnbound(head ++ "pub fn F(comptime R: type) usize { const info = @typeInfo(R).@\"struct\"; return info.fields.len; }", pack.access, 1, 0);
}

test "receivers through a guard's resolved type, builtins, destructuring, loop values and choices a build leaves out are decided" {
    const head = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst builtin = @import(\"builtin\");\nconst Shared = struct { closed: bool };\n";
    // A guard passed to a private `anytype` parameter is a guard by its resolved type.
    try expectJudged(head ++ "fn wait(held: anytype) void { _ = held.value().closed; }\npub fn f(g: *aegis.BlockingGuarded(Shared), io: std.Io) void { var held = g.acquireUncancelable(io); defer held.release(); wait(&held); }", pack.access, true, 0);
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
    const head = "const std = @import(\"std\");\nconst aegis = @import(\"aegis\");\nconst O = aegis.Order(&.{ .{ .name = \"a\" }, .{ .name = \"b\", .after = &.{0} } });\n";
    // An atomic's cell is private; a copy is a second cell.
    try expectJudged(head ++ "pub fn f(a: *aegis.Atomic(u32)) void { _ = a.cell; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(a: aegis.Atomic(u32)) u32 { const b = a; return a.load(.acquire) + b.load(.acquire); }", pack.copies, true, 1);
    // A task's context: private stack, a copy is a second context.
    try expectJudged(head ++ "pub fn f(c: *O.Context, i: *aegis.InitContext) usize { return c.used + i.used; }", pack.access, true, 2);
    try expectJudged(head ++ "fn use(_: *const O.Context) void {}\npub fn f(c: O.Context) void { var d = c; _ = &d; use(&c); }", pack.copies, true, 1);
    // An ordered lock's base is private; its ordered acquisitions give guards released by `deinit`.
    try expectJudged(head ++ "const L = O.Ordered(aegis.BlockingGuarded(u32), 0);\npub fn f(l: *L) void { _ = l.base; }", pack.access, true, 1);
    try expectJudged(head ++ "const L = O.Ordered(aegis.BlockingGuarded(u32), 0);\npub fn f(l: *L, c: *O.Context, io: std.Io) void { var g = l.acquireOrderedUncancelable(io, c); g.value().* += 1; }", pack.cleanup, true, 1);
    try expectJudged(head ++ "const L = O.Ordered(aegis.BlockingGuarded(u32), 0);\npub fn f(l: *L, c: *O.Context, io: std.Io) void { var g = l.acquireOrderedUncancelable(io, c); defer g.deinit(io); g.value().* += 1; }", pack.cleanup, true, 0);
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
    // Recursion over a type, on comptime parameters alone or making a type, is the types' depth.
    try expectJudged(head ++ "pub fn read(text: Text) usize { _ = text.readForParse(); return @intFromBool(deep(u8, &.{})) + @sizeOf(Wrap(u8)); }\nfn deep(comptime T: type, comptime seen: []const type) bool { return switch (@typeInfo(T)) { .pointer => |i| deep(i.child, seen ++ .{T}), else => false }; }\nfn Wrap(comptime T: type) type { return if (@sizeOf(T) > 8) T else Wrap([2]T); }", pack.recursion, true, 0);
    // A runtime value given with the type follows the data of a type that holds itself.
    try expectJudged(head ++ "pub fn read(text: Text) bool { const b = text.readForParse(); return same([]const u8, b, b); }\nfn same(comptime T: type, a: T, b: T) bool { return switch (@typeInfo(T)) { .pointer => |i| same(i.child, a[0], b[0]), else => a == b }; }", pack.recursion, true, 1);
}

test "A006 strict: a guard that leaves before the call, the way the depth steps, against a bound the input does not choose" {
    const head = "const aegis = @import(\"aegis\");\nconst Text = aegis.input.Untrusted([]const u8);\n";
    const param = "pub fn read(text: Text) error{TooDeep}!usize { return nest(text.readForParse(), 0); }\n";
    // The guard after the call: each level recurses before it checks.
    try expectJudged(head ++ param ++ "fn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (bytes.len == 0) return 0; const r = 1 + try nest(bytes[1..], depth + 1); if (depth > 64) return error.TooDeep; return r; }", pack.recursion, true, 1);
    try expectJudged(head ++ param ++ "fn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (depth > 64) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], depth + 1); }", pack.recursion, true, 0);
    // A guard in a branch that does not lead to the call.
    try expectJudged(head ++ param ++ "fn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (bytes.len == 0) { if (depth > 64) return error.TooDeep; return 0; } return 1 + try nest(bytes[1..], depth + 1); }", pack.recursion, true, 1);
    // The wrong way: a growing depth held at least a bound.
    try expectJudged(head ++ param ++ "fn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (depth < 64) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], depth + 1); }", pack.recursion, true, 1);
    // A step of nothing.
    try expectJudged(head ++ param ++ "fn nest(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (depth > 64) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], depth + 0); }", pack.recursion, true, 1);
    // A bound the input chooses: its length.
    try expectJudged(head ++ "pub fn read(text: Text) error{TooDeep}!usize { const bytes = text.readForParse(); return nest(bytes, 0, bytes.len); }\nfn nest(bytes: []const u8, depth: usize, most: usize) error{TooDeep}!usize { if (depth > most) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], depth + 1, most); }", pack.recursion, true, 1);
    try expectJudged(head ++ "pub fn read(text: Text) error{TooDeep}!usize { const bytes = text.readForParse(); return nest(bytes, 0, 64); }\nfn nest(bytes: []const u8, depth: usize, most: usize) error{TooDeep}!usize { if (depth > most) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], depth + 1, most); }", pack.recursion, true, 0);
    // A shrinking budget the input gives, and one the program gives.
    try expectJudged(head ++ "pub fn read(text: Text) error{TooDeep}!usize { const bytes = text.readForParse(); return nest(bytes, bytes.len); }\nfn nest(bytes: []const u8, budget: usize) error{TooDeep}!usize { if (budget == 0) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], budget - 1); }", pack.recursion, true, 1);
    try expectJudged(head ++ "pub fn read(text: Text) error{TooDeep}!usize { return nest(text.readForParse(), 64); }\nfn nest(bytes: []const u8, budget: usize) error{TooDeep}!usize { if (budget == 0) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], budget - 1); }", pack.recursion, true, 0);
    // A field moved only in a `defer`, after the call; and a helper called after the call.
    const parser = "pub fn read(text: Text) error{TooDeep}!void { var p: Parser = .{ .bytes = text.readForParse() }; try p.value(); }\n";
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn value(p: *Parser) error{TooDeep}!void { defer p.depth += 1; if (p.depth > 64) return error.TooDeep; if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn enter(p: *Parser) error{TooDeep}!void { p.depth += 1; if (p.depth > 64) return error.TooDeep; }\n fn value(p: *Parser) error{TooDeep}!void { if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.value(); try p.enter(); } };", pack.recursion, true, 1);
    // The field moved and guarded before the call, the guard first.
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn value(p: *Parser) error{TooDeep}!void { if (p.depth > 64) return error.TooDeep; p.depth += 1; defer p.depth -= 1; if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.value(); } };", pack.recursion, true, 0);
}

test "A006 strict: the depth is the one the cycle carries, passed on in its place, never reset" {
    const head = "const aegis = @import(\"aegis\");\nconst Text = aegis.input.Untrusted([]const u8);\n";
    // A stepped depth handed on as another parameter, and the guarded parameter given a constant.
    try expectJudged(head ++ "pub fn read(text: Text) error{TooDeep}!usize { return nest(text.readForParse(), 0, 0); }\nfn nest(bytes: []const u8, depth: u8, other: u8) error{TooDeep}!usize { _ = other; if (depth > 64) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try nest(bytes[1..], 0, depth + 1); }", pack.recursion, true, 1);
    // Across two functions, one of which starts the depth over, and one that hands it on.
    const outer = "pub fn read(text: Text) error{TooDeep}!usize { return outer(text.readForParse(), 0); }\nfn outer(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (depth > 64) return error.TooDeep; if (bytes.len == 0) return 0; return 1 + try inner(bytes[1..], depth + 1); }\n";
    try expectJudged(head ++ outer ++ "fn inner(bytes: []const u8, depth: u8) error{TooDeep}!usize { _ = depth; if (bytes.len == 0) return 0; return 1 + try outer(bytes[1..], 0); }", pack.recursion, true, 1);
    try expectJudged(head ++ outer ++ "fn inner(bytes: []const u8, depth: u8) error{TooDeep}!usize { if (bytes.len == 0) return 0; return 1 + try outer(bytes[1..], @as(u8, depth)); }", pack.recursion, true, 0);
    // A field of another object: a local counter, a fresh child, a fresh helper's receiver.
    const parser = "pub fn read(text: Text) error{TooDeep}!void { var p: Parser = .{ .bytes = text.readForParse() }; try p.value(); }\n";
    try expectJudged(head ++ parser ++ "const Counter = struct { n: u8 = 0 };\nconst Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn value(p: *Parser) error{TooDeep}!void { var scratch: Counter = .{}; scratch.n += 1; if (scratch.n > 64) return error.TooDeep; if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn value(p: *Parser) error{TooDeep}!void { p.depth += 1; if (p.depth > 64) return error.TooDeep; if (p.bytes.len == 0) return; var child: Parser = .{ .bytes = p.bytes[1..] }; try child.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn enter(p: *Parser) error{TooDeep}!void { p.depth += 1; if (p.depth > 64) return error.TooDeep; }\n fn value(p: *Parser) error{TooDeep}!void { var fresh: Parser = .{ .bytes = &.{} }; try fresh.enter(); if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.value(); } };", pack.recursion, true, 1);
    // The field reset elsewhere on the cycle, by its name, by `@field`, or the whole struct; a
    // larger undo than the step.
    const value = " fn value(p: *Parser) error{TooDeep}!void { p.depth += 1; defer p.depth -= 1; if (p.depth > 64) return error.TooDeep; if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.list(); }\n";
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { p.depth = 0; try p.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { @field(p, \"depth\") = 0; try p.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { const q = p; q.* = .{ .bytes = q.bytes }; try p.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n fn value(p: *Parser) error{TooDeep}!void { p.depth += 1; defer p.depth -= 2; if (p.depth > 64) return error.TooDeep; if (p.bytes.len == 0) return; p.bytes = p.bytes[1..]; try p.list(); }\n fn list(p: *Parser) error{TooDeep}!void { try p.value(); } };", pack.recursion, true, 1);
    // Its address taken, and the field reset through it; the twin takes another field's.
    try expectJudged(head ++ parser ++ "fn zero(d: *u8) void { d.* = 0; }\nconst Parser = struct { bytes: []const u8, depth: u8 = 0, other: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { zero(&p.depth); try p.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "fn zero(d: *u8) void { d.* = 0; }\nconst Parser = struct { bytes: []const u8, depth: u8 = 0, other: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { zero(&p.other); try p.value(); } };", pack.recursion, true, 0);
    // Reset by a destructure.
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0, other: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { p.depth, p.other = .{ 0, 1 }; try p.value(); } };", pack.recursion, true, 1);
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0, other: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { _, p.other = .{ 0, 1 }; try p.value(); } };", pack.recursion, true, 0);
    // Handed on through a second function, and called twice there.
    try expectJudged(head ++ parser ++ "const Parser = struct { bytes: []const u8, depth: u8 = 0,\n" ++ value ++ " fn list(p: *Parser) error{TooDeep}!void { try p.value(); try p.value(); } };", pack.recursion, true, 0);
}

test "A006 strict: a call through anything but a function is undecided" {
    const head = "const aegis = @import(\"aegis\");\nconst Text = aegis.input.Untrusted([]const u8);\n";
    try expectJudged(head ++ "const Step = *const fn ([]const u8) usize;\npub fn read(text: Text, step: Step) usize { return step(text.readForParse()); }", pack.recursion, false, 0);
    try expectJudged(head ++ "fn step(bytes: []const u8) usize { return bytes.len; }\npub fn read(text: Text) usize { return step(text.readForParse()); }", pack.recursion, true, 0);
}

test "A001 finds a public source's field written in place, by name, by @field or through its address" {
    const head = "const err = @import(\"aegis\").err;\nconst Other = struct { bytes: []const u8 };\n";
    try expectJudged(head ++ "pub fn f(secret: []const u8) err.PublicSource { var p = err.PublicSource.classify(\"fixed label\", \"ok\"); p.bytes = secret; return p; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(p: *err.PublicSource, secret: []const u8) void { p.bytes = secret; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(p: *err.PublicSource, secret: []const u8) void { @field(p, \"bytes\") = secret; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(p: *err.PublicSource) *[]const u8 { return &p.bytes; }", pack.access, true, 1);
    // Another type's field of the same name, and a read, are not.
    try expectJudged(head ++ "pub fn f(o: *Other, p: *const err.PublicSource, secret: []const u8) usize { o.bytes = secret; return p.bytes.len; }", pack.access, true, 0);
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
    // A labeled block's `break`, also through an `if` it gives, takes the block's place.
    try expectJudged(head ++ "pub fn f(b: []const u8, n: u8) err.PublicSource { return switch (n) { 0 => blk: { break :blk if (b.len == 0) .{ .bytes = b } else .{ .bytes = b[1..] }; }, else => .{ .bytes = b } }; }", pack.access, true, 3);
    try expectJudged(head ++ "const Event = union(enum) { text: Other, bytes: Other };\npub fn f(b: []const u8, n: u8) Other { return switch (n) { 0 => blk: { break :blk if (b.len == 0) .{ .bytes = b } else .{ .bytes = b[1..] }; }, else => .{ .bytes = b } }; }", pack.access, true, 0);
    // `classify` is the way; a literal of another type with the same fields is not one, nor an
    // anonymous one.
    try expectJudged(head ++ "pub fn f(b: []const u8) void { show(err.PublicSource.classify(\"a reviewed name\", b)); }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(b: []const u8) void { take(.{ .bytes = b }); const o: Other = .{ .bytes = b }; _ = o; const a = .{ .bytes = b }; _ = a; }", pack.access, true, 0);
    // A literal naming other fields cannot be one; a place that does not resolve is undecided.
    try expectUnbound(head ++ "pub fn f(b: []const u8, sink: anytype) void { sink.put(.{ .bytes = b, .more = 1 }); }", pack.access, 1, 0);
    try expectJudged(head ++ "pub fn f(b: []const u8, sink: anytype) void { sink.put(.{ .bytes = b }); }", pack.access, false, 0);
}

test "A001 reads a runtime machine's state as its backing field" {
    const head = "const aegis = @import(\"aegis\");\nconst S = enum { open, done };\nconst E = enum { finish };\nconst Machine = aegis.state.Machine(S, E, .{ .initial = .open, .terminal = &.{.done}, .edges = &.{.{ .from = .open, .on = .finish, .to = .done }} });\n";
    try expectJudged(head ++ "pub fn f(m: *Machine.Runtime(void)) S { return m.state; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(m: *Machine.Runtime(void)) S { return m.current(); }", pack.access, true, 0);
}

test "A003 releases std's Server by its deinit" {
    // std.Io.net.Server closes its socket in `deinit`, its one release (reactor's tests).
    const head = "const std = @import(\"std\");\nfn listen() std.Io.net.Server { return .{}; }\n";
    try expectJudgedStd(head ++ "pub fn f() void { var s = listen(); defer s.deinit(); }", pack.cleanup, true, 0);
    try expectJudgedStd(head ++ "pub fn f() void { var s = listen(); s.deinit(); }", pack.cleanup, true, 0);
    try expectJudgedStd(head ++ "pub fn f() void { var s = listen(); _ = &s; }", pack.cleanup, true, 1);
}

test "A003 lends an owner to a callee by its kind's release, through a call or @call's tuple" {
    // A callee that closes a std handle it is lent releases it (a guard's `deinit` does not);
    // one that reads only its members or discards it hands it back held.
    const head = "const std = @import(\"std\");\nfn connect() std.Io.net.Stream { return .{}; }\nfn shut(s: *std.Io.net.Stream) void { s.close(); }\nfn peek(s: *std.Io.net.Stream) void { _ = s.handle; }\nfn ignore(s: *std.Io.net.Stream) void { _ = s; }\n";
    try expectJudgedStd(head ++ "pub fn f() void { var s = connect(); defer s.close(); shut(&s); }", pack.cleanup, false, 0);
    try expectJudgedStd(head ++ "pub fn f() void { var s = connect(); defer s.close(); peek(&s); ignore(&s); }", pack.cleanup, true, 0);
    try expectJudgedStd(head ++ "pub fn f() void { var s = connect(); defer s.close(); @call(.auto, peek, .{&s}); }", pack.cleanup, true, 0);
}

test "A003 releases an array of std handles by closing each copy a loop takes" {
    // A std handle is a value: `for (pair) |s| s.close()` closes each of the pair's handles, as
    // `for (&pair) |*s| s.close()` does; a loop that only reads them closes none.
    const head = "const std = @import(\"std\");\nfn pairOf() [2]std.Io.net.Stream { return .{ .{}, .{} }; }\n";
    try expectJudgedStd(head ++ "pub fn f() void { const pair = pairOf(); defer for (pair) |s| s.close(); }", pack.cleanup, true, 0);
    try expectJudgedStd(head ++ "pub fn f() void { var pair = pairOf(); defer for (&pair) |*s| s.close(); }", pack.cleanup, true, 0);
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

test "a made container's declaration naming a type another call makes is read with the call's bindings" {
    // Not with every caller's: `Outer` is also made over a guard, which `Outer(Plain).Record`
    // does not hold.
    const head = "const aegis = @import(\"aegis\");\nfn Inner(comptime T: type) type { return struct { pub const Record = struct { value: T }; }; }\npub fn Outer(comptime T: type) type { return opaque { const State = Inner(T); pub const Record = State.Record; }; }\nconst Plain = struct { data: u32 };\n";
    try expectJudged(head ++ "pub fn f(rec: Outer(Plain).Record) void { _ = rec.value.data; }\npub fn g(o: *Outer(aegis.Guarded(u32))) void { _ = o; }", pack.access, true, 0);
    try expectJudged(head ++ "pub fn f(rec: Outer(aegis.Guarded(u32)).Record) void { _ = rec.value.data; }\npub fn g(o: *Outer(Plain)) void { _ = o; }", pack.access, true, 1);
}

test "A001 refutes an unresolved receiver by the other members the file reads of the same expression" {
    // `p.name` beside `p.value`: no aegis type with a `value` field has a `name`.
    try expectUnbound("const aegis = @import(\"aegis\");\npub fn f(access: anytype) void { for (access.pairs()) |p| { _ = p.name; _ = p.value; } }", pack.access, 1, 0);
    // Without another member the receiver stays undecided.
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(access: anytype) void { for (access.pairs()) |p| _ = p.value; }", pack.access, false, 0);
}

test "A003 leaves an unresolved acquisition undecided even where no aegis function can be it: the program's own may return an owner, decided at each binding where a generic's parameter gives it" {
    // No aegis `read` takes two arguments, but `access` may be the program's own type, whose
    // `read` returns an owner: a method of an `anytype` parameter's value gives what each
    // binding makes, checked at the binding, as a type parameter's function does (below).
    try expectUnbound("const aegis = @import(\"aegis\");\npub fn f(access: anytype) !void { const text = try access.read([]const u8, 4); _ = text; }", pack.cleanup, 1, 0);
    try expectUnbound("const aegis = @import(\"aegis\");\npub fn f(access: anytype, io: anytype) !void { var g = try access.read(io); _ = &g; }", pack.cleanup, 1, 0);
    // A `comptime` value holds nothing at run time: a call on it is judged where it is written.
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(comptime access: anytype, io: anytype) !void { var g = try access.read(io); _ = &g; }", pack.cleanup, false, 0);
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(raw: *anyopaque, io: anytype, id: u32, comptime T: type) !void { const owner: T = @ptrCast(@alignCast(raw)); const got = try owner.read(io, id); _ = got; }", pack.cleanup, false, 0);
    // A function of a type parameter gives what each binding makes, checked at the binding.
    try expectUnbound("const aegis = @import(\"aegis\");\npub fn f(io: anytype, id: u32, comptime T: type) !void { const got = try T.read(io, id); _ = got; }", pack.cleanup, 1, 0);
}

test "A002 reads operators and a tuple written in place" {
    // An operator gives no struct: a copy of its result copies no owner, nor an `if` one of whose branches is one.
    try expectUnbound("pub fn f(comptime Int: type, a: Int, b: Int, g: fn () Int) void { const d = a - b; var x = if (a > b) g() + 1 else g(); const e = d; const y = x; _ = e; _ = y; _ = &x; }", pack.copies, 1, 0);
    // An `inline for` over `.{ a, b }` takes each element in turn.
    try expectJudged("pub fn f() void { inline for (.{ @as(u8, 1), @as(u16, 2) }) |v| { var copy = v; _ = &copy; } }", pack.copies, true, 0);
}

test "a comptime condition settled on the path decides a receiver chosen by it" {
    const head = "const aegis = @import(\"aegis\");\nconst Direct = struct { data: u64, lock: bool };\n";
    // The direct side after `if (wrapped) return ...;`, in an `else`, or under `if (!wrapped)`.
    try expectUnbound(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (wrapped) { var held = owner.acquire(); defer held.deinit(); return held.value().*; } return owner.data; }", pack.access, 1, 0);
    try expectUnbound(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (wrapped) return 0 else return owner.data; }", pack.access, 1, 0);
    try expectUnbound(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (!wrapped) { owner.lock = true; } return 0; }", pack.access, 1, 0);
    // Through a type function of the condition: `Owner(wrapped)` read with what the path settles.
    try expectUnbound(head ++ "fn Owner(comptime wrapped: bool) type { return if (wrapped) aegis.Guarded(u64) else Direct; }\npub fn f(comptime wrapped: bool, owner: *Owner(wrapped)) u64 { if (wrapped) return 0; return owner.data; }", pack.access, 1, 0);
    // A container a type function makes with the condition, its field chosen by it.
    try expectUnbound(head ++ "fn State(comptime wrapped: bool) type { return struct { m: if (wrapped) aegis.Guarded(u64) else Direct }; }\npub fn f(comptime wrapped: bool, s: *State(wrapped)) u64 { if (wrapped) return 0; const owner = &s.m; return owner.data; }", pack.access, 1, 0);
    // On the wrapped side the same access is the aegis owner's backing field.
    try expectUnbound(head ++ "pub fn f(comptime wrapped: bool, owner: if (wrapped) *aegis.Guarded(u64) else *Direct) u64 { if (!wrapped) return 0; return owner.data; }", pack.access, 1, 1);
    // Two instantiations of one type function are two alternatives, each read with its call.
    try expectUnbound(head ++ "fn Line(comptime T: type) type { return struct { value: T }; }\npub fn f(comptime wrapped: bool, line: if (wrapped) Line(aegis.Guarded(u64)) else Line(Direct)) u64 { return line.value.data; }", pack.access, 1, 1);
    try expectUnbound(head ++ "fn Line(comptime T: type) type { return struct { value: T }; }\npub fn f(comptime wrapped: bool, line: if (wrapped) Line(Direct) else Line(Direct)) u64 { return line.value.data; }", pack.access, 1, 0);
}

test "a switch prong on a comptime enum parameter settles it for what the prong reads" {
    const head = "const aegis = @import(\"aegis\");\nconst Plain = struct { data: u32 };\nfn Line(comptime T: type) type { return struct { value: T }; }\nconst A = struct { fn next(_: *A) ?Line(Plain) { return null; } };\nconst C = struct { fn next(_: *C, n: u32) Line(aegis.Guarded(u32)) { _ = n; return undefined; } };\nconst D = enum { a, c };\n";
    // Inside `.a`, the reader the earlier switch on `d` chose is `A`'s alone.
    try expectUnbound(head ++ "pub fn f(comptime d: D) u32 { var r = switch (d) { .a => A{}, .c => C{} }; return switch (d) { .a => r.next().?.value.data, .c => 0 }; }", pack.access, 1, 0);
    try expectUnbound(head ++ "pub fn f(comptime d: D) u32 { var r = switch (d) { .a => A{}, .c => C{} }; const line = switch (d) { .a => r.next().?, .c => r.next(1) }; _ = line; return switch (d) { .a => 0, .c => r.next(1).value.data }; }", pack.access, 1, 1);
    // Read outside a prong, the receiver is either reader's.
    try expectUnbound(head ++ "pub fn f(comptime d: D) u32 { var r = switch (d) { .a => A{}, .c => C{} }; const line = switch (d) { .a => r.next().?, .c => r.next(1) }; return line.value.data; }", pack.access, 1, 1);
}

test "a generic's copies of its parameter are decided where the parameter is bound" {
    const head = "const aegis = @import(\"aegis\");\npub fn clone(comptime T: type, value: T) T { var result = value; _ = &result; return result; }\npub fn outer(comptime T: type, value: T) T { return clone(T, value); }\n";
    // At the definition the copy is the bindings' obligation.
    try expectUnbound(head, pack.copies, 2, 0);
    // A binding to a plain type copies no owner; one to an owner does, there or through a
    // generic that passes it on.
    try expectJudged(head ++ "const P = struct { n: u8 };\npub fn f(p: P) void { _ = clone(P, p); _ = outer(P, p); }", pack.copies, true, 0);
    try expectUnbound(head ++ "pub fn f(s: aegis.Secret(u32)) void { _ = clone(aegis.Secret(u32), s); }", pack.copies, 1, 1);
    try expectJudged(head ++ "pub fn f(s: aegis.Secret(u32)) void { _ = outer(aegis.Secret(u32), s); }", pack.copies, true, 1);
}

test "what a generic acquires by its type parameter is decided where the parameter is bound" {
    const head = "const aegis = @import(\"aegis\");\nconst Plain = struct { n: u8, fn init(_: struct {}) Plain { return .{ .n = 0 }; } };\nfn digest(comptime Hash: type) void { var h = Hash.init(.{}); _ = &h; }\npub fn sign(comptime Hash: type) void { digest(Hash); }\n";
    // At the definition, and through a generic passing the parameter on, it is each binding's.
    try expectUnbound(head, pack.cleanup, 1, 0);
    try expectJudged(head ++ "pub fn f() void { sign(Plain); digest(Plain); }", pack.cleanup, true, 0);
    // A binding to an owner with a release leaves it undecided there: the generic's paths are
    // not walked per binding. A guarded value owes none; its guard does.
    try expectJudged(head ++ "pub fn f() void { sign(aegis.Guarded(u32)); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f() void { sign(aegis.Secret([4]u8)); }", pack.cleanup, false, 0);
    // Bound in turn from a tuple of pairs written in place, destructured.
    try expectJudged(head ++ "const Other = struct { n: u16, fn init(_: struct {}) Other { return .{ .n = 0 }; } };\npub fn f() void { inline for (.{ .{ Plain, .plain }, .{ Other, .other } }) |pair| { const Hash, const name = pair; _ = name; sign(Hash); } }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f() void { inline for (.{ .{ Plain, .plain }, .{ aegis.Secret([4]u8), .secret } }) |pair| { const Hash, const name = pair; _ = name; sign(Hash); } }", pack.cleanup, false, 0);
}

test "a generic's copies of its anytype parameter are decided where the argument is bound" {
    const head = "const aegis = @import(\"aegis\");\npub fn keep(value: anytype) void { var copy = value; _ = &copy; }\npub fn on(value: anytype) void { keep(value); }\nconst P = struct { n: u8 };\n";
    // At the definition the copy is the arguments' obligation, also through a generic passing it on.
    try expectUnbound(head, pack.copies, 2, 0);
    try expectJudged(head ++ "pub fn f(p: P) void { keep(p); on(p); }", pack.copies, true, 0);
    try expectUnbound(head ++ "pub fn f(s: aegis.Secret(u32)) void { keep(s); }", pack.copies, 1, 1);
    try expectJudged(head ++ "pub fn f(s: aegis.Secret(u32)) void { on(s); }", pack.copies, true, 1);
    // A pointer's copies are aliases.
    try expectUnbound(head ++ "pub fn f(s: *aegis.Secret(u32)) void { keep(s); }", pack.copies, 1, 0);
    // What a generic passes on of its parameter other than the parameter itself (what calling
    // it returns, what it points to) is read where the parameter is bound, also from a function
    // declared in the generic and through a generic passing the parameter on (parley's typed
    // tool handler, its result written out).
    const handlers = head ++ "fn Sig(comptime h: anytype) type { return struct { const Args = @typeInfo(@TypeOf(h)).@\"fn\".params.len; }; }\npub fn typed(comptime handler: anytype) fn () anyerror!void { const S = Sig(handler); const E = struct { fn call() anyerror!void { const out = if (S.Args == 0) handler() else blk: { break :blk handler(1); }; const value = out catch |err| return err; keep(value); } }; return E.call; }\npub fn add(comptime handler: anytype) void { _ = typed(handler); }\npub fn direct(comptime handler: anytype) void { const value = handler() catch return; keep(value); }\npub fn through(p: anytype) void { keep(p.*); }\n";
    try expectUnbound(handlers, pack.copies, 5, 0);
    try expectUnbound(handlers ++ "fn plain() !P { return undefined; }\npub fn f() void { direct(plain); _ = typed(plain); add(plain); }", pack.copies, 2, 0);
    try expectUnbound(handlers ++ "fn secret() !aegis.Secret(u32) { return undefined; }\npub fn f() void { direct(secret); }", pack.copies, 4, 1);
    try expectUnbound(handlers ++ "fn secret() !aegis.Secret(u32) { return undefined; }\npub fn f() void { _ = typed(secret); }", pack.copies, 4, 1);
    try expectUnbound(handlers ++ "fn secret() !aegis.Secret(u32) { return undefined; }\npub fn f() void { add(secret); }", pack.copies, 3, 1);
    try expectUnbound(handlers ++ "pub fn f(s: *aegis.Secret(u32), p: *P) void { through(s); through(p); }", pack.copies, 4, 1);
    // An argument that does not resolve leaves the call undecided.
    try expectJudged(head ++ "pub fn f(g: fn () @import(\"missing\").T) void { keep(g()); }", pack.copies, false, 0);
    // A `comptime` parameter's value holds nothing at run time: its copies are no owner's.
    const fixed = "const aegis = @import(\"aegis\");\nfn digits(comptime value: anytype) usize { var rest = value; _ = &rest; return 1; }\nfn width(comptime T: type, comptime value: T) usize { const copy = value; _ = copy; return 1; }\n";
    try expectJudged(fixed ++ "pub fn f(g: fn () @import(\"missing\").T) usize { return digits(g()) + width(u8, 1); }", pack.copies, true, 0);
    // Arguments plain as written: a vector, an enum's or a union's tag, `{}`, a tuple of plain
    // values, an element of a typed array of plain tuples.
    const shapes = head ++ "const Color = enum { red, @\"with space\" };\nconst Shape = union(enum) { circle: f32, empty };\n";
    try expectUnbound(shapes ++ "pub fn f() void { keep(@as(@Vector(3, u8), @splat(1))); keep(Color.red); keep(Color.@\"with space\"); keep(Shape.empty); keep({}); keep(.{ 1, \"two\" }); }", pack.copies, 1, 0);
    try expectUnbound(shapes ++ "pub fn f() void { const cases = [_]struct { f64, []const u8 }{ .{ 0.5, \"0.5\" } }; for (cases) |case| keep(case[0]); }", pack.copies, 1, 0);
    // A tuple holding an owner holds that owner: its copy is a finding.
    try expectUnbound(shapes ++ "pub fn f(s: aegis.Secret(u32)) void { keep(.{ s, 1 }); }", pack.copies, 1, 1);
    // A tuple holding what does not resolve is undecided.
    try expectJudged(shapes ++ "pub fn f(s: aegis.Secret(u32), g: fn () @import(\"missing\").T) void { keep(.{ s, g() }); }", pack.copies, false, 0);
    // A choice of types whose pointers, and arrays of them, are aliases.
    try expectUnbound(head ++ "pub fn f(comptime n: u8) void { const T = switch (n) { 0 => [*]const u8, 1 => [0]*const u8, else => P }; const v: T = undefined; keep(v); }", pack.copies, 3, 0);
    // A tuple's element, by its number, also where an `inline for` gives the tuple.
    const typed = head ++ "fn take(comptime T: type, value: T) void { var copy = value; _ = &copy; }\n";
    try expectUnbound(typed ++ "pub fn f() void { inline for (.{ .{ P, 1 }, .{ u8, 2 } }) |case| take(case[0], undefined); }", pack.copies, 2, 0);
    try expectUnbound(typed ++ "pub fn f() void { inline for (.{ .{ P, 1 }, .{ aegis.Secret(u32), 2 } }) |case| take(case[0], undefined); }", pack.copies, 2, 1);
    // A type built from field types holds what they do: `@Struct`, `@Tuple`, through `@as` of
    // types and `@splat`, and made by a type function of no parameter.
    try expectUnbound(head ++ "const Built = @Struct(.auto, null, &.{\"a\"}, &.{P}, &@splat(.{}));\npub fn f(b: Built, t: @Tuple(&@as([2]type, @splat(P)))) void { keep(b); keep(t); }", pack.copies, 1, 0);
    try expectUnbound(head ++ "const Built = @Struct(.auto, null, &.{\"a\"}, &.{aegis.Secret(u32)}, &@splat(.{}));\npub fn f(b: Built) void { keep(b); }", pack.copies, 1, 1);
    try expectUnbound(head ++ "fn Made() type { var types: [1]type = @splat(P); _ = &types; return @Struct(.auto, null, &.{\"a\"}, &types, &@splat(.{})); }\npub fn f(m: Made()) void { keep(m); }", pack.copies, 1, 0);
    try expectUnbound(head ++ "fn Made() type { var types: [1]type = @splat(aegis.Secret(u32)); _ = &types; return @Struct(.auto, null, &.{\"a\"}, &types, &@splat(.{})); }\npub fn f(m: Made()) void { keep(m); }", pack.copies, 1, 1);
    // `@Pointer(...)` makes a pointer: a copy of what `Untrusted.readForParse` gives is an
    // alias (relic's credential answer read a line at a time).
    try expectJudged("const aegis = @import(\"aegis\");\npub fn f(answer: aegis.input.Untrusted([]const u8)) usize { var rest = answer.readForParse(); var line = rest; rest = rest[1..]; line = line[0..1]; return line.len + rest.len; }", pack.copies, true, 0);
    // A function type written in place is reflected as a declared function is: a vtable's
    // field types, each a function pointer, give their parameters' types (shakedown's
    // simulated `Io` calls); one of them an owner makes a copy of the parameter a finding.
    const vtable = "pub fn slot(comptime name: []const u8) @FieldType(VTable, name) {\n    const info = @typeInfo(@typeInfo(@FieldType(VTable, name)).pointer.child).@\"fn\";\n    const params = info.param_types;\n    return &struct {\n        fn f(u: ?*anyopaque, a: params[1].?) void {\n            _ = u;\n            keep(.{a});\n        }\n    }.f;\n}\n";
    try expectUnbound(head ++ "const VTable = struct { crash: *const fn (?*anyopaque) void, open: *const fn (?*anyopaque, u32) void, close: *const fn (?*anyopaque, P) void };\n" ++ vtable, pack.copies, 2, 0);
    try expectUnbound(head ++ "const VTable = struct { crash: *const fn (?*anyopaque) void, open: *const fn (?*anyopaque, u32) void, close: *const fn (?*anyopaque, aegis.Secret(u32)) void };\n" ++ vtable, pack.copies, 2, 1);
    // A field's type read by `@FieldType` of a made container is the making call's, also in a
    // generic's result written in terms of its `anytype` parameter (chronicle's journal state
    // seen through its owner).
    const layered = head ++ "fn Inner(comptime E: type) type { return struct { pub const Record = struct { event: E }; pub fn copy(r: Record) void { keep(r.event); } }; }\nfn Outer(comptime E: type) type { return struct { const State = Inner(E); pub const Record = State.Record; }; }\nfn state(owner: anytype) *Inner(@FieldType(@typeInfo(@TypeOf(owner)).pointer.child.Record, \"event\")) { return @ptrCast(owner); }\nfn quiet(owner: anytype) void { _ = state(owner); }\n";
    try expectUnbound(layered ++ "pub fn f() void { var o: Outer(P) = undefined; quiet(&o); }", pack.copies, 1, 0);
}

test "an owner whose address a function of the program releases on every path is released by the call" {
    const head = "const aegis = @import(\"aegis\");\nfn clean(_: *u32) void {}\nconst O = aegis.own.Owned(u32, clean);\nconst M = aegis.own.MustUse(u32, \"read the count\");\n";
    // Released by a deferred `deinit` on every path, under the `comptime` flag the call passes;
    // a result obligation taken and checked.
    const owned = "fn owned(comptime wrapped: bool, owner: if (wrapped) *O else *u32, fail: bool) void { if (wrapped) { defer owner.deinit(); if (fail) return; owner.borrowMut().* +%= 1; } else { owner.* +%= 1; } }\n";
    const must = "fn must(owner: *M, out: *u32) void { owner.take(out); owner.deinit(); }\n";
    try expectJudged(head ++ owned ++ "pub fn f(fail: bool) void { var owner = O.init(1); owned(true, &owner, fail); }", pack.cleanup, true, 0);
    try expectJudged(head ++ must ++ "pub fn f() u32 { var out: u32 = 0; var owner = M.init(1); must(&owner, &out); return out; }", pack.cleanup, true, 0);
    // Released again after the call: a second cleanup.
    try expectJudged(head ++ owned ++ "pub fn f(fail: bool) void { var owner = O.init(1); owned(true, &owner, fail); owner.deinit(); }", pack.cleanup, true, 1);
    // A path that keeps it held, a flag the call does not pass as a literal, or a function that
    // passes it on stay undecided.
    try expectJudged(head ++ "fn half(owner: *O, fail: bool) void { if (fail) return; owner.deinit(); }\npub fn f(fail: bool) void { var owner = O.init(1); half(&owner, fail); }", pack.cleanup, false, 0);
    try expectJudged(head ++ owned ++ "pub fn f(comptime wrapped: bool, fail: bool) void { var owner = O.init(1); owned(wrapped, &owner, fail); }", pack.cleanup, false, 0);
    try expectJudged(head ++ "var kept: ?*O = null;\nfn keep(owner: *O) void { kept = owner; }\npub fn f() void { var owner = O.init(1); keep(&owner); }", pack.cleanup, false, 0);
    // Passed on to a function that releases it, the pointer it was given.
    try expectJudged(head ++ "fn release(owner: *O) void { owner.deinit(); }\nfn on(owner: *O) void { release(owner); }\npub fn f() void { var owner = O.init(1); on(&owner); }", pack.cleanup, true, 0);
    // A function in a file the run did not select is the program's, read as one that is.
    const other = "pub fn release(owner: anytype) void { owner.deinit(); }\npub fn half(owner: anytype, fail: bool) void { if (fail) return; owner.deinit(); }";
    const imported = "const other = @import(\"other.zig\");\n";
    try expectJudgedWithFile(head ++ imported ++ "pub fn f() void { var owner = O.init(1); other.release(&owner); }", other, pack.cleanup, true, 0);
    try expectJudgedWithFile(head ++ imported ++ "pub fn f() void { var owner = O.init(1); other.release(&owner); owner.deinit(); }", other, pack.cleanup, true, 1);
    try expectJudgedWithFile(head ++ imported ++ "pub fn f(fail: bool) void { var owner = O.init(1); other.half(&owner, fail); }", other, pack.cleanup, false, 0);
}

test "an owner handed on by its move is transferred where the result is returned, stored or bound, and a call given its address may take it only where it returns" {
    const head = "const aegis = @import(\"aegis\");\nfn shut(_: *u32) void {}\nconst O = aegis.own.Owned(u32, shut);\nconst R = struct { o: O, n: u32 = 0 };\nfn ready(_: u32) bool { return true; }\nfn g() !void {}\n";
    // Moved into what is returned, into storage the function does not hold, or into a local
    // A003 follows from there; returned on one branch and released on the other.
    try expectJudged(head ++ "pub fn f() !R { var o = O.init(1); errdefer o.deinit(); try g(); return .{ .o = o.move() }; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f(slot: *R) !void { var o = O.init(1); errdefer o.deinit(); try g(); slot.* = .{ .o = o.move() }; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f() ?O { var o = O.init(1); if (ready(o.borrow().*)) return o.move(); o.deinit(); return null; }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f() void { var o = O.init(1); var x = o.move(); x.deinit(); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "pub fn f() void { var o = O.init(1); var x = o.move(); _ = x.borrow(); }", pack.cleanup, true, 1);
    // Released after the move, or by an errdefer on an error exit after it, one in the same
    // literal included: a witness each.
    try expectJudged(head ++ "pub fn f(slot: *R) void { var o = O.init(1); slot.* = .{ .o = o.move() }; o.deinit(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(slot: *R) !void { var o = O.init(1); errdefer o.deinit(); slot.* = .{ .o = o.move() }; try g(); }", pack.cleanup, true, 1);
    try expectJudged(head ++ "pub fn f(slot: *R) !void { var o = O.init(1); errdefer o.deinit(); slot.* = .{ .o = o.move(), .n = blk: { try g(); break :blk 1; } }; }", pack.cleanup, true, 1);
    // A function given the owner's address that releases or moves it on every path takes it,
    // tried or handled; released again by the caller's errdefer, a witness.
    const register = "fn register(o: *O, out: *R) !void { errdefer o.deinit(); try g(); out.* = .{ .o = o.move() }; }\n";
    try expectJudged(head ++ register ++ "pub fn f(out: *R) !void { var o = O.init(1); try register(&o, out); }", pack.cleanup, true, 0);
    try expectJudged(head ++ register ++ "pub fn f(out: *R) void { var o = O.init(1); register(&o, out) catch return; }", pack.cleanup, true, 0);
    try expectJudged(head ++ register ++ "pub fn f(out: *R) !void { var o = O.init(1); errdefer o.deinit(); try register(&o, out); }", pack.cleanup, true, 1);
    // One that moves it where it returns and leaves it held on its errors takes it there: the
    // caller's errdefer covers the rest, an optional one moved by its capture included.
    try expectJudged(head ++ "fn with(o: *O) !R { try g(); return .{ .o = o.move() }; }\npub fn f() !R { var o = O.init(1); errdefer o.deinit(); return with(&o); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "fn with(o: *O, w: ?*O) !struct { o: O, w: ?O } { try g(); return .{ .o = o.move(), .w = if (w) |x| x.move() else null }; }\npub fn f() !struct { o: O, w: ?O } { var a = O.init(1); errdefer a.deinit(); var b = O.init(2); errdefer b.deinit(); return with(&a, &b); }", pack.cleanup, true, 0);
    try expectJudged(head ++ "fn with(o: *O) !R { try g(); return .{ .o = o.move() }; }\npub fn f() !R { var o = O.init(1); return with(&o); }", pack.cleanup, false, 0);
}

test "A002 decides a shim whose parameters' types are reflected from a function type, passed on as a tuple a generic copies, and an arm for an arity no function has" {
    var project = try fixture(
        \\const std = @import("std");
        \\const VTable = struct { two: *const fn (?*anyopaque, u32) void, three: *const fn (?*anyopaque, u32, []const u8) void };
        \\const Core = struct { cwd: u32 = 0 };
        \\fn keep(c: *const Core, args: anytype) @TypeOf(args) {
        \\    var local = args;
        \\    inline for (0..args.len) |i| {
        \\        if (@TypeOf(args[i]) == u32) local[i] = c.cwd;
        \\    }
        \\    return local;
        \\}
        \\fn invoke(comptime name: []const u8, u: ?*anyopaque, args: anytype, ret: usize) void {
        \\    _ = name;
        \\    _ = ret;
        \\    const c: *const Core = @ptrCast(@alignCast(u));
        \\    const local = keep(c, args);
        \\    _ = local;
        \\}
        \\pub fn slot(comptime name: []const u8) @FieldType(VTable, name) {
        \\    const info = @typeInfo(@typeInfo(@FieldType(VTable, name)).pointer.child).@"fn";
        \\    const params = info.param_types;
        \\    return switch (params.len) {
        \\        2 => &struct {
        \\            fn f(u: ?*anyopaque, a: params[1].?) void {
        \\                return invoke(name, u, .{a}, @returnAddress());
        \\            }
        \\        }.f,
        \\        3 => &struct {
        \\            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?) void {
        \\                return invoke(name, u, .{ a, b }, @returnAddress());
        \\            }
        \\        }.f,
        \\        // No function of the table takes four: Zig compiles this arm in no build.
        \\        4 => &struct {
        \\            fn f(u: ?*anyopaque, a: params[1].?, b: params[2].?, d: params[3].?) void {
        \\                return invoke(name, u, .{ a, b, d }, @returnAddress());
        \\            }
        \\        }.f,
        \\        else => unreachable,
        \\    };
        \\}
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), count(report, pack.copies));
    // `slot` is a public generic nothing binds: undecided at its name alone, the shim decided.
    try std.testing.expectEqual(Undecided{ .unbound = 1, .other = 0 }, undecidedOf(report, pack.copies));
}

test "A006 names each call that untrusted input reaches and that does not resolve, by its place and spelling" {
    var project = try fixture(
        \\const aegis = @import("aegis");
        \\const ext = @import("missing");
        \\const Text = aegis.input.Untrusted([]const u8);
        \\pub fn read(text: Text) usize {
        \\    return walk(text.readForParse());
        \\}
        \\fn walk(bytes: []const u8) usize {
        \\    const sum = ext.hash(bytes);
        \\    return sum.len();
        \\}
    );
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.recursion, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(!report.complete);
    var named = false;
    for (report.coverage) |entry| if (entry.rule != null and entry.rule.? == pack.recursion) {
        named = std.mem.find(u8, entry.detail, ":8 `ext.hash`") != null and std.mem.find(u8, entry.detail, ":9 `sum.len`") != null;
    };
    try std.testing.expect(named);
}

test "A002 reads an array's length as a number: a literal holding it beside plain data copies no owner, beside an owner it copies that owner" {
    const head = "const S = @import(\"aegis\").Secret;\nconst T = struct { n: usize, tag: u8 };\nconst H = struct { n: usize, s: S(u32) };\nconst base = [_]T{.{ .n = 0, .tag = 1 }};\n";
    try expectJudged(head ++ "pub fn f() usize { const x = base ++ [_]T{.{ .n = base.len, .tag = 2 }}; return x.len; }", pack.copies, true, 0);
    try expectJudged(head ++ "pub fn f(h: *H) void { const copy: H = .{ .n = base.len, .s = h.s }; _ = copy; }", pack.copies, true, 1);
}

/// A003's and A019's findings and undecided sites over `source`, with A003 on beside A019 or
/// A019 alone.
fn cleanupAndUndefined(source: []const u8, with_cleanup: bool) !struct { cleanup: usize, cleanup_undecided: usize, undefined_read: usize, undefined_undecided: usize } {
    var project = try fixture(source);
    defer project.deinit();
    const both: glint.Config = .{ .enabled = @splat(false), .selections = &.{ .{ .rule = pack.cleanup, .level = .gate }, .{ .rule = pack.unsafe_set, .level = .gate } } };
    const alone: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.unsafe_set, .level = .gate }} };
    var report = try glint.runConfigured(std.testing.allocator, &project, if (with_cleanup) both else alone, .{ .project_rules = &pack.rules });
    defer report.deinit();
    var undecided: [2]usize = .{ 0, 0 };
    for (report.coverage) |item| if (item.rule) |rule| {
        if (rule == pack.cleanup) undecided[0] += 1;
        if (rule == pack.unsafe_set) undecided[1] += 1;
    };
    return .{ .cleanup = count(report, pack.cleanup), .cleanup_undecided = undecided[0], .undefined_read = count(report, pack.unsafe_set), .undefined_undecided = undecided[1] };
}

test "A019 leaves a use after cleanup of a local A003 follows to A003 where it runs, and reads it itself where A003 is off" {
    const head = "const std = @import(\"std\");\nconst Bytes = @import(\"aegis\").SecretBytes;\n";
    // Read after its deinit (whose `self.* = undefined` leaves it undefined): A003's alone.
    const after = head ++ "pub fn f(gpa: std.mem.Allocator) !usize { var b = try Bytes.init(gpa, 4); b.deinit(gpa); return b.len(); }";
    const shared = try cleanupAndUndefined(after, true);
    try std.testing.expectEqual(@as(usize, 1), shared.cleanup);
    try std.testing.expectEqual(@as(usize, 0), shared.undefined_read + shared.undefined_undecided);
    const own = try cleanupAndUndefined(after, false);
    try std.testing.expectEqual(@as(usize, 1), own.undefined_read);
    // Read through an alias taken before its deinit: A003's where it runs, and A019's own finding
    // where it is off (the alias followed), cleared by neither.
    const alias = head ++ "pub fn f(gpa: std.mem.Allocator) !usize { var b = try Bytes.init(gpa, 4); const p = &b; b.deinit(gpa); return p.len(); }";
    const shared_alias = try cleanupAndUndefined(alias, true);
    try std.testing.expect(shared_alias.cleanup + shared_alias.cleanup_undecided != 0);
    try std.testing.expectEqual(@as(usize, 0), shared_alias.undefined_read + shared_alias.undefined_undecided);
    const own_alias = try cleanupAndUndefined(alias, false);
    try std.testing.expectEqual(@as(usize, 1), own_alias.undefined_read);
    try std.testing.expectEqual(@as(usize, 0), own_alias.undefined_undecided);
}

/// An aegis whose acquisitions return their guard wrapped in `MustUse`, and one whose wrapped
/// payload names nothing: each acquisition read by its declared result, through the wrapper.
const wrapped_root =
    \\pub fn MustUse(comptime T: type, comptime why: []const u8) type {
    \\    _ = why;
    \\    return struct {
    \\        data: T,
    \\        pub fn take(m: *@This()) T { return m.data; }
    \\    };
    \\}
    \\pub fn Guarded(comptime T: type) type {
    \\    return struct {
    \\        const Self = @This();
    \\        data: T,
    \\        lock: bool = false,
    \\        pub fn acquire(o: *Self) MustUse(Guard, "release it") { return .{ .data = .{ .owner = o } }; }
    \\        pub fn obtain(o: *Self) MustUse(@import("absent.zig").Missing, "release it") { _ = o; unreachable; }
    \\        pub const Guard = struct {
    \\            owner: *Self,
    \\            pub fn deinit(g: *Guard) void { g.owner.lock = false; }
    \\        };
    \\    };
    \\}
    \\pub const lint_rules = .{ .version = 1, .roles = .{
    \\    .{ .type = MustUse, .role = .must_use },
    \\    .{ .type = Guarded, .role = .guarded },
    \\    .{ .type = .{ .generic = Guarded, .member = .Guard }, .role = .guard },
    \\} };
;
fn wrappedLocks(program: []const u8) !struct { findings: usize, complete: bool } {
    const own = glint.AegisPack.package;
    var project = try P.init(std.testing.allocator, &.{
        .{ .name = "consumer", .bytes = program },
        .{ .name = "root.zig", .bytes = wrapped_root, .selected = false, .package = own.name, .fingerprint = own.fingerprint },
    }, &.{.{ .from = 0, .spelling = "aegis", .target = 1 }}, .{});
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.lock_order, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    return .{ .findings = count(report, pack.lock_order), .complete = report.complete };
}
test "an acquisition is read by its declared result through MustUse; one whose wrapped payload does not resolve is undecided, never no acquisition" {
    const both = try wrappedLocks("const aegis = @import(\"aegis\");\npub fn f(a: *aegis.Guarded(u32), b: *aegis.Guarded(u32)) void {\n    var ga = a.acquire();\n    var gb = b.acquire();\n    _ = &ga;\n    _ = &gb;\n}\n");
    try std.testing.expectEqual(@as(usize, 1), both.findings);
    const unknown = try wrappedLocks("const aegis = @import(\"aegis\");\npub fn f(a: *aegis.Guarded(u32), b: *aegis.Guarded(u32)) void {\n    var ga = a.acquire();\n    var gb = b.obtain();\n    _ = &ga;\n    _ = &gb;\n}\n");
    try std.testing.expectEqual(@as(usize, 0), unknown.findings);
    try std.testing.expect(!unknown.complete);
}

test "where only a value's role is known, a field every type of that role keeps is A001's, one only some keep is undecided, one none keeps is not" {
    const head = "const aegis = @import(\"aegis\");\nconst wide = @import(\"builtin\").cpu.arch == .x86_64;\nconst Tag = struct {};\nfn clean(_: *u32) void {}\nconst Pool = if (wide) aegis.handle.SlotPool(u8, Tag, .{}) else aegis.handle.RunPool(u8, Tag);\nconst O = if (wide) aegis.own.Owned(u32, clean) else aegis.own.OwnedIo(u32, cleanIo);\nfn cleanIo(_: *u32, _: @import(\"std\").Io) void {}\n";
    // Owned and OwnedIo both keep `data` behind their operations: a finding, whichever it is.
    try expectJudged(head ++ "pub fn f(o: *O) u32 { return o.data; }", pack.access, true, 1);
    // SlotPool keeps `used`, RunPool does not: which one it is, glint does not know.
    try expectJudged(head ++ "pub fn f(p: *Pool) usize { return p.used; }", pack.access, false, 0);
    // No type of the role keeps `extra`: none of their fields, nothing to report.
    try expectJudged(head ++ "pub fn f(p: *Pool) usize { return p.extra; }", pack.access, true, 0);
}

test "a result obligation's teardown after its discharge is clean; before it, the finding is at the teardown; a discharge after it is a use after its end" {
    const head = "const aegis = @import(\"aegis\");\nconst M = aegis.own.MustUse(u32, \"read the count\");\n";
    try expectJudged(head ++ "pub fn f(out: *u32) void {\n    var m = M.init(1);\n    m.take(out);\n    m.deinit();\n}", pack.cleanup, true, 0);
    // One finding, at the teardown, and none again at the block's end.
    try expectJudged(head ++ "pub fn f() void {\n    var m = M.init(1);\n    m.deinit();\n}", pack.cleanup, true, 1);
    // The teardown's, and the take after it.
    try expectJudged(head ++ "pub fn f(out: *u32) void {\n    var m = M.init(1);\n    m.deinit();\n    m.take(out);\n}", pack.cleanup, true, 2);
}

/// An aegis whose guard hands its release on to an optional hand-off: the move happens only
/// when the call gives one.
const handoff_root =
    \\pub fn Guarded(comptime T: type) type {
    \\    return struct {
    \\        const Self = @This();
    \\        data: T,
    \\        lock: bool = false,
    \\        pub fn acquire(o: *Self) Guard { o.lock = true; return .{ .owner = o }; }
    \\        pub const Guard = struct {
    \\            owner: *Self,
    \\            pub fn deinit(g: *Guard) void { g.owner.lock = false; }
    \\            pub fn handOff(g: *Guard) Handoff { return .{ .owner = g.owner }; }
    \\            pub fn tryHandOff(g: *Guard) ?Handoff { return .{ .owner = g.owner }; }
    \\        };
    \\        pub const Handoff = struct {
    \\            owner: *Self,
    \\            pub fn release(h: *Handoff) void { h.owner.lock = false; }
    \\        };
    \\    };
    \\}
    \\pub const lint_rules = .{
    \\    .version = 1,
    \\    .roles = .{
    \\        .{ .type = Guarded, .role = .guarded, .internal = .{ .lock, .data } },
    \\        .{ .type = .{ .generic = Guarded, .member = .Guard }, .role = .guard, .internal = .{.owner} },
    \\        .{ .type = .{ .generic = Guarded, .member = .Handoff }, .role = .handoff, .internal = .{.owner} },
    \\    },
    \\    .pairs = .{
    \\        .{ .type = .{ .generic = Guarded, .member = .Guard }, .release = .{.deinit}, .transfer = .{ .handOff, .tryHandOff } },
    \\        .{ .type = .{ .generic = Guarded, .member = .Handoff }, .release = .{.release} },
    \\    },
    \\};
;
fn handedCleanup(program: []const u8) !struct { findings: usize, complete: bool } {
    const own = glint.AegisPack.package;
    var project = try P.init(std.testing.allocator, &.{
        .{ .name = "consumer", .bytes = program },
        .{ .name = "root.zig", .bytes = handoff_root, .selected = false, .package = own.name, .fingerprint = own.fingerprint },
    }, &.{.{ .from = 0, .spelling = "aegis", .target = 1 }}, .{});
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.cleanup, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    return .{ .findings = count(report, pack.cleanup), .complete = report.complete };
}
test "a guard's release moved to its hand-off by declaration; to an optional hand-off, only when one is given, which is undecided" {
    const head = "const aegis = @import(\"aegis\");\nconst G = aegis.Guarded(u32);\n";
    const moved = try handedCleanup(head ++ "pub fn f(b: *G) G.Handoff {\n    var g = b.acquire();\n    return g.handOff();\n}\n");
    try std.testing.expect(moved.complete);
    try std.testing.expectEqual(@as(usize, 0), moved.findings);
    const maybe = try handedCleanup(head ++ "pub fn f(b: *G) ?G.Handoff {\n    var g = b.acquire();\n    return g.tryHandOff();\n}\n");
    try std.testing.expect(!maybe.complete);
    try std.testing.expectEqual(@as(usize, 0), maybe.findings);
}

test "the private fields aegis's first list missed are A001's: a reader-writer owner's admission limit, a dense map's regions and rooms, a secondary map's index and entries" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst P = aegis.handle.SlotPool(u32, Tag, .{ .generation = u64 });\n";
    try expectJudged(head ++ "pub fn f(g: *aegis.RwGuarded(u32)) usize { return g.limit; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(m: *aegis.handle.DenseSlotMap(u32, Tag)) void { _ = m.value_region; _ = m.key_room; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(m: *aegis.handle.SecondaryMap(P, u8)) void { _ = m.index; _ = m.first; _ = m.room; _ = m.gpa; }", pack.access, true, 3);
}

test "a public generic nothing the run compiles binds is undecided at its name for each rule of the pack, and gates where one gates" {
    const program =
        \\pub fn unbound(x: anytype) void { _ = x; }
        \\pub fn bound(x: anytype) void { _ = x; }
        \\fn private(x: anytype) void { _ = x; }
        \\const Hidden = struct { pub fn hidden(x: anytype) void { _ = x; } };
        \\pub fn List(comptime T: type) type {
        \\    return struct { pub fn push(_: *@This(), x: anytype) void { _ = x; _ = T; } };
        \\}
        \\pub const Params = struct { a: u32 };
        \\pub fn Curve(comptime params: Params) type {
        \\    return struct { pub fn order() u32 { return params.a; } };
        \\}
        \\pub fn Kept(comptime params: Params) type {
        \\    return struct { pub fn order() u32 { return params.a; } };
        \\}
        \\pub fn main() void {
        \\    bound(@as(u8, 1));
        \\    _ = Kept(.{ .a = 1 }).order();
        \\    _ = Hidden;
        \\}
    ;
    const gpa = std.testing.allocator;
    var project = try fixture(program);
    defer project.deinit();
    for ([_]bool{ false, true }) |gates| {
        var report = try glint.runConfigured(gpa, &project, .{ .enabled = @splat(false), .selections = &.{ .{ .rule = pack.access, .level = if (gates) .gate else .report }, .{ .rule = pack.cleanup, .level = .report } } }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        var noted: std.ArrayList(u8) = .empty;
        defer noted.deinit(gpa);
        for (report.coverage) |entry| if (std.mem.eql(u8, entry.detail, unbound_generic)) {
            const tree = &project.at(entry.file).file.tree;
            const token = for (0..tree.tokens.len) |t| {
                if (tree.tokenStart(@intCast(t)) == entry.start) break t;
            } else unreachable; // unreachable: a note starts at its generic's name
            try noted.print(gpa, "{s} {s}\n", .{ entry.rule_name, tree.tokenSlice(@intCast(token)) });
        };
        // `unbound`, the type functions `List` (its method `push` is noted at it) and `Curve`, whose
        // `comptime` parameter is no type (Zig's one definition of a generic), by each rule;
        // `bound`, `Kept`, the private and the unreachable ones not, nor aegis's own generics, files
        // no rule of the pack checks.
        try std.testing.expectEqualStrings("A001 unbound\nA001 List\nA001 Curve\nA003 unbound\nA003 List\nA003 Curve\n", noted.items);
        if (gates) try std.testing.expect(!report.complete);
    }
}
