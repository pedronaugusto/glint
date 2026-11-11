const std = @import("std");
const glint = @import("glint");
const P = glint.Project;
const pack = glint.AegisPack;
const aegis_sources = @import("aegis_sources");
fn fixture(bytes: []const u8) !P {
    return aegis_sources.project(std.testing.allocator, bytes);
}
const config: glint.Config = .{ .enabled = .empty, .selections = &.{
    .{ .rule = pack.access, .level = .report },
    .{ .rule = pack.scalar, .level = .report },
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

test "morning adopted aegis gate accepts selection and preserves finding levels" {
    var project = try fixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }");
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: one direct backing access.
    try std.testing.expectEqual(glint.Config.Level.gate, report.diagnostics[0].level);
}

test "morning adopted scalar gate reports bypasses and blocks unresolved receivers" {
    var project = try fixture("const Checked = @import(\"aegis\").int.Checked; pub fn f() void { const v = Checked(u32).init(1); _ = v.raw() + 2; }");
    defer project.deinit();
    const gated: glint.Config = .{ .enabled = .empty, .selections = &.{.{ .rule = pack.scalar, .level = .gate }} };
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
    };
    inline for (cases) |case| {
        var project = try fixture(case[1]);
        defer project.deinit();
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = case[0], .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expect(!report.complete);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: unresolved ownership records coverage rather than an allegation.
    }
    var plain = try fixture("const Plain = struct { material: u32 }; pub fn f(v: Plain) void { _ = v.material; }");
    defer plain.deinit();
    var clean = try glint.runConfigured(std.testing.allocator, &plain, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer clean.deinit();
    try std.testing.expect(clean.complete);
    try std.testing.expectEqual(@as(usize, 0), clean.diagnostics.len); // safe: resolved unrelated containers carry no published operation obligation.
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
    var selections = config.selections[0..2].*;
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
        .{ pack.access, "const G = @import(\"aegis\").Guarded; pub fn f(g: *G(u32).@\"Guard\") void { _ = g.@\"owner\"; }" },
    };
    inline for (cases) |case| {
        var project = try fixture(case[1]);
        defer project.deinit();
        try std.testing.expectEqual(.parsed, project.sources[0].file.status);
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = case[0], .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    try std.testing.expectEqual(@as(usize, 2), count(report, pack.scalar)); // safe: fixture counts are representable.
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.scalar, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: one raw arithmetic bypass.
}
test "identical source under another module is not aegis" {
    var project = try flatFixture("const S = @import(\"vault\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }", .{ .vault = "pub const Secret = @import(\"Secret.zig\").Secret;" });
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: the vault module's Secret is not aegis's.
}
test "a role aegis declares that does not resolve is reported where aegis is imported, never a quiet gate" {
    // `Guarded`'s container declares no `Gaurd`: a misspelt member compiles (an enum literal), so
    // only the reader sees it.
    var project = try flatFixture("const S = @import(\"aegis\").Secret; pub fn f(s: *S(u32)) void { _ = s.material; }", .{ .root = comptime flat_declared ++ "\n" ++ flatRules("Gaurd") });
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    const gated: glint.Config = .{ .enabled = .empty, .selections = &.{.{ .rule = pack.scalar, .level = .gate }} };
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.scalar, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    return .{ .complete = report.complete, .findings = count(report, rule), .undecided = undecidedOf(report, rule) };
}
fn expectJudged(source: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try fixture(source);
    defer project.deinit();
    try std.testing.expectEqual(.parsed, project.sources[0].file.status);
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
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

fn expectJudgedWithDependency(source: []const u8, dependency: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try aegis_sources.projectWithDependency(std.testing.allocator, source, dependency);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try expectReport(report, rule, complete, findings);
}

fn expectJudgedWithLib(source: []const u8, lib: []const u8, rule: glint.Rule, complete: bool, findings: usize) !void {
    var project = try aegis_sources.projectWith(std.testing.allocator, source, lib);
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = rule, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    }) |case| {
        const source = try std.mem.concat(std.testing.allocator, u8, &.{ head, case[1] });
        defer std.testing.allocator.free(source);
        var project = try aegis_sources.projectWithSources(std.testing.allocator, source, &extra, &imports);
        defer project.deinit();
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = case[0], .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = role_probe_id, .level = .gate }} }, .{ .project_rules = &.{role_probe} });
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
    try std.testing.expectEqual(null, std.mem.find(u8, pinned, "pub const Queue"));
    const program = "const bounded = @import(\"aegis\").bounded;\npub fn f(r: *bounded.Ring(u8, 4), b: *bounded.RingBuffer(u8)) void { _ = r.head; _ = b.used; }";
    // Clean of drift: both backing reads found through the one name each.
    {
        var project = try aegis_sources.project(gpa, program);
        defer project.deinit();
        var report = try glint.runConfigured(gpa, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
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
        var report = try glint.runConfigured(gpa, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
        defer report.deinit();
        try std.testing.expect(!report.complete);
        var drifted = false;
        for (report.coverage) |entry| if (entry.rule != null) {
            drifted = drifted or std.mem.eql(u8, entry.detail, "aegis's lint_rules at src/root.zig:126: a reference that does not resolve; the roles it declares are not all read in this file");
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
    var report = try glint.runConfigured(gpa, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.access, .level = .gate }} }, .{ .project_rules = &pack.rules });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 3), count(report, pack.access));
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
    var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = pack.lock_order, .level = .gate }} }, .{ .project_rules = &pack.rules });
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

test "the private fields aegis's first list missed are A001's: a reader-writer owner's admission limit, a dense map's regions and rooms, a secondary map's index and entries" {
    const head = "const aegis = @import(\"aegis\");\nconst Tag = struct {};\nconst P = aegis.handle.SlotPool(u32, Tag, .{ .generation = u64 });\n";
    try expectJudged(head ++ "pub fn f(g: *aegis.RwGuarded(u32)) usize { return g.limit; }", pack.access, true, 1);
    try expectJudged(head ++ "pub fn f(m: *aegis.handle.DenseSlotMap(u32, Tag)) void { _ = m.value_region; _ = m.key_room; }", pack.access, true, 2);
    try expectJudged(head ++ "pub fn f(m: *aegis.handle.SecondaryMap(P, u8)) void { _ = m.index; _ = m.first; _ = m.room; _ = m.gpa; }", pack.access, true, 3);
}
