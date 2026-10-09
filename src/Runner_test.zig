//! Compatibility contracts use complete contrasting source inputs and stable IDs.
const std = @import("std");
const glint = @import("glint");

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
    }, &.{.{ .from = glint.Project.FileId.fromRaw(0), .spelling = "dep", .target = glint.Project.FileId.fromRaw(1) }}, .{}); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z011, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 7), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(report.complete);
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
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(glint.Rule.Z009, report.diagnostics[0].rule);
    try std.testing.expect(report.complete);
}

test "compatibility Z016 splits only conjunction of the mapped standard assertion" {
    const root = "const std = @import(\"std\"); const assert = std.debug.assert; pub fn f(a: bool, b: bool) void { assert(a and b); assert(a or b); }";
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root },
        .{ .name = "standard", .bytes = "pub const debug = struct { pub fn assert(ok: bool) void { _ = ok; } };", .selected = false },
    }, &.{.{ .from = glint.Project.FileId.fromRaw(0), .target = glint.Project.FileId.fromRaw(1), .spelling = "std" }}, .{}); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z016, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(report.complete);
    try check(.Z016, "const std = struct { const debug = struct { fn assert(ok: bool) void { _ = ok; } }; }; pub fn f(a: bool, b: bool) void { std.debug.assert(a and b); }", 0);
}

test "compatibility deprecation follows aliases and symbolic returned containers" {
    try check(.Z011, "/// Deprecated: use fresh.\nfn old() void {} const alias = old; pub fn run() void { alias(); }", 1);
    try check(.Z011, "fn Factory(comptime T: type) type { return struct { value: T,\n /// Deprecated: use fresh.\n pub fn old() void {} }; } const S = Factory(u8); pub fn run() void { S.old(); }", 1);
    try check(.Z011, "/// Not deprecated.\nfn old() void {} pub fn run() void { old(); _ = \"Deprecated: string\"; }", 0);
}

test "compatibility Z024 reports bytes exceeding the configured boundary" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "line", .bytes = "// 12345678\r\n" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z024, true);
    config.max_line_length = 10;
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(@as(u32, 10), report.diagnostics[0].span.start); // safe: explicit compile-time type selection; the value is representable in that type.
}

test "compatibility strict stale suppressions and exhausted facts are incomplete" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "// glint-ignore: Z013 -- stale regression site\npub const x = 1;" }}, &.{}, .{});
    defer project.deinit();
    var config: glint.Config = .{ .strict_suppressions = true };
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expect(!report.complete);
    try std.testing.expectEqual(@as(usize, 1), report.stale_suppressions); // safe: explicit compile-time type selection; the value is representable in that type.
    config.strict_suppressions = false;
    config.fact_budget = 0;
    var exhausted = try glint.run(std.testing.allocator, &project, config);
    defer exhausted.deinit();
    try std.testing.expect(!exhausted.complete);
}

test "compatibility suppression rejects multiple distinct binding sites" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const a = @import(\"a\"); const b = @import(\"b\"); // glint-ignore: Z013 -- one site only\n" }}, &.{}, .{});
    defer project.deinit();
    try std.testing.expectError(error.AmbiguousSuppression, glint.run(std.testing.allocator, &project, .{}));
}

test "compatibility deprecation resolves escaped member identity" {
    try check(.Z011, "const S = struct {\n /// Deprecated: use fresh.\n pub fn @\"old name\"() void {} }; pub fn run() void { S.@\"old name\"(); }", 1);
}

test "review Z006 resolves callable aliases instead of their spelling" {
    try check(.Z006, "fn snake_fn() void {} const callableAlias = snake_fn; pub fn run() void { callableAlias(); }", 0);
    try check(.Z006, "const snake_alias = factory; fn factory() type { return u8; } const TypeAlias = snake_alias; pub const value: TypeAlias() = 1;", 0);
}

test "review Z006 declines computed naming facts" {
    try check(.Z006, "const dep = @import(\"unmapped\"); const computedAlias = @field(dep, \"Type\"); pub fn run() void { _ = computedAlias; }", 0);
}

test "review canonical naming contrasts" {
    try check(.Z001, "pub fn Bad_name() void {}", 1);
    try check(.Z001, "pub fn goodName() void {}", 0);
    try check(.Z005, "pub fn factory() type { return u8; }", 1);
    try check(.Z005, "pub fn Factory() type { return u8; }", 0);
    try check(.Z006, "const badName = 1;", 1);
    try check(.Z006, "const good_name = 1;", 0);
    try check(.Z014, "const errors = error{Bad};", 1);
    try check(.Z014, "const Errors = error{Bad};", 0);
    try check(.Z031, "pub fn _private() void {}", 1);
    try check(.Z031, "pub fn visible() void {}", 0);
    try check(.Z032, "pub fn readXML() void {}", 1);
    try check(.Z032, "pub fn readXml() void {}", 0);
}

test "review preserves names fixed by external ABIs" {
    try check(.Z001, "extern \"c\" fn proc_listchildpids(u32) c_int;", 0);
    try check(.Z032, "extern \"kernel32\" fn GetXML(u32) u32;", 0);
    try check(.Z031, "export fn __entry_point() void {}", 0);
    try check(.Z031, "pub fn __private() void {}", 1);
}

test "review acronym casing still covers concrete type aliases" {
    try check(.Z032, "pub const XMLParser = struct { value: u8 };", 1);
    try check(.Z032, "pub const XmlParser = struct { value: u8 };", 0);
}

test "review preserves resolved external callable aliases" {
    try check(.Z006, "const c = struct { extern \"c\" fn CancelIoEx(u32) void; }; pub const CancelIoEx = c.CancelIoEx;", 0);
    try check(.Z006, "fn run() void {} const RunAlias = run; pub fn f() void { RunAlias(); }", 1);
}

test "review typed scalar aliases are values, not type acronyms" {
    try check(.Z032, "const c = struct { pub const GWINSZ: u32 = 1; }; pub const GWINSZ: u32 = c.GWINSZ;", 0);
    try check(.Z006, "pub const badName: u32 = 1;", 1);
    try check(.Z006, "pub const good_name: u32 = 1;", 0);
}

test "review private imports used through the actual file identity are not dead" {
    try check(.Z013, "const Self = @This(); const object = @import(\"dep\"); pub const exports = struct { pub const exposed = Self.object; };", 0);
    try check(.Z013, "const object = @import(\"dep\"); const Other = struct { pub const object = 1; }; pub const exposed = Other.object;", 1);
}

test "G2 Z026 family reason policy includes cleanup and distinguishes handled errors" {
    try check(.Z026, "fn fallible() error{Failure}!void {} pub fn f() void { fallible() catch {}; defer fallible() catch {}; }", 2);
    try check(.Z026, "fn fallible() error{Failure}!void {} pub fn f() void { fallible() catch { return; }; }", 0);
    try check(.Z026, "fn fallible() error{Failure}!void {}\npub fn f() void { fallible() catch {}; } // glint-ignore: Z026 -- best-effort cleanup; no recovery available\n", 0);
    try check(.Z026, "const text = \"catch {} // glint-ignore: Z026 -- fake\"; pub fn f() void { _ = text; }", 0);
}

test "G2 Z012 family API report respects public aliases receivers and suppression" {
    try check(.Z012, "const Hidden = struct {}; pub fn create() Hidden { return .{}; }", 1);
    try check(.Z012, "const Hidden = struct {}; pub fn create() ?*Hidden { return null; }", 1);
    try check(.Z012, "const Hidden = struct {}; pub const Visible = Hidden; pub fn create() Hidden { return .{}; }", 0);
    try check(.Z012, "pub const Visible = struct { pub fn read(self: @This()) void { _ = self; } };", 0);
    try check(.Z012, "const Hidden = struct {};\n// glint-ignore: Z012 -- inference-only factory intentionally hides representation\npub fn create() Hidden { return .{}; }", 0);
}

test "G2 amended policies are explicit family choices and count suppressed sites" {
    try std.testing.expect(!(@as(glint.Config, .{})).has(.Z012)); // safe: select the default configuration type for this policy assertion.
    try std.testing.expect(!(@as(glint.Config, .{})).has(.Z026)); // safe: select the default configuration type for this policy assertion.
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "policy", .bytes = "const Hidden = struct {};\n// glint-ignore: Z012 -- inference-only factory\npub fn create() Hidden { return .{}; }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z012, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: expected count fits usize.
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: expected count fits usize.
}

test "G2 dead-private model resolves member calls hooks and literal reflection before counting" {
    try check(.D001, "fn unused() void {} pub fn live() void {}", 1);
    try check(.D001, "const S = struct { fn read(self: S) u8 { _ = self; return 1; } }; pub fn live(s: S) u8 { return s.read(); }", 0);
    try check(.D001, "const S = struct { const needed = 1; }; pub fn live() void { _ = @field(S, \"needed\"); }", 0);
    try check(.D001, "pub const S = struct { fn format(self: S) void { _ = self; } };", 0);
    try check(.D001, "fn retained() void {}\n// glint-ignore: D001 -- deliberate fixture declaration tests unused-name reporting\nfn unused() void {}\npub fn live() void { retained(); }", 0);
}

test "G2 dead-private never accuses dynamic reflection generics or unresolved calls" {
    try check(.D001, "const S = struct { const needed = 1; }; pub fn live(name: []const u8) void { _ = @field(S, name); }", 0);
    try check(.D001, "fn Box(comptime T: type) type { return struct { value: T }; }", 0);
    try check(.D001, "const unknown = @import(\"external\"); fn unused() void {} pub fn live() void { unknown.f(); }", 0);
}

test "G2 casts safety-off catches and length follow configured code policy" {
    try check(.P001, "pub fn f(x: u32) u8 { return @intCast(x); }", 1);
    try check(.P001, "pub fn f(x: u32) u8 { return @intCast(x); } // safe: bounded input validated by caller\n", 0);
    try check(.P001, "const text = \"// safe: forged\"; pub fn f(x: u32) u8 { _ = text; return @intCast(x); }", 1);
    try check(.P002, "pub fn f() void { @setRuntimeSafety(false); }", 1);
    try check(.P002, "pub fn f() void { @setRuntimeSafety(false); } // safe: measured parser loop, length validated at entry\n", 0);
    try check(.P004, "fn fail() error{Failure}!void {} pub fn f() void { fail() catch unreachable; }", 1);
    try check(.P004, "fn fail() error{Failure}!void {}\n// unreachable: this implementation cannot emit Failure\npub fn f() void { fail() catch unreachable; }", 0);
    try check(.P004, "fn fail() error{Failure}!void {} test { fail() catch unreachable; }", 0);
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "length", .bytes = "pub fn f() void {\n\n\n}\n" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.P003, true);
    config.max_function_lines = 3;
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: single overlong function.
    config.function_exceptions = &.{.{ .function = "f", .lines = 4, .reason = "audited dispatch" }};
    var allowed = try glint.run(std.testing.allocator, &project, config);
    defer allowed.deinit();
    try std.testing.expectEqual(@as(usize, 0), allowed.diagnostics.len); // safe: exception matches exact body budget.
}

test "G2 function-length type constructors subtract returned container bodies" {
    const source = "pub fn Box(comptime T: type) type {\n    return struct {\n        value: T,\n        a: u8,\n        b: u8,\n        c: u8,\n        fn get(self: @This()) T {\n            return self.value;\n        }\n    };\n}\n";
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "types", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.P003, true);
    config.max_function_lines = 4;
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: constructor and method each fit the limit.
}

test "G2 hook retention includes nested private namespaces" {
    try check(.D001, "pub const Outer = struct { const Inner = struct { fn format() void {} }; };", 0);
}

test "G2 disallowed policy follows qualified declaration identity and aliases" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "policy", .bytes = "const A = struct { fn raw() void {} }; const B = struct { fn raw() void {} }; const alias = A.raw; pub fn run() void { alias(); B.raw(); }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.P006, true);
    config.disallowed = &.{.{ .source = "policy", .declaration = "A.raw", .reason = "this project requires the guarded API", .replacement = "checked" }};
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    // The alias definition and its call refer to A.raw; B.raw is a distinct declaration.
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: exact fixture identity uses.
    config.disallowed = &.{.{ .source = "missing", .declaration = "A.raw", .reason = "requires guarded API", .replacement = "checked" }};
    config.selections = &.{.{ .rule = .P006, .level = .gate }};
    var missing = try glint.run(std.testing.allocator, &project, config);
    defer missing.deinit();
    try std.testing.expect(!missing.complete);
    try std.testing.expectEqual(@as(usize, 0), missing.diagnostics.len); // safe: no invented missing declaration.
}

test "G2 policy configuration rejects blank reasons empty qualifiers and stale exceptions" {
    var config = glint.Config.none();
    config.disallowed = &.{.{ .source = "module", .declaration = "A.raw", .reason = " ", .replacement = "checked" }};
    try std.testing.expectError(error.InvalidSelection, config.validate());
    config.disallowed = &.{.{ .source = "module", .declaration = "A..raw", .reason = "requires guard", .replacement = "checked" }};
    try std.testing.expectError(error.InvalidSelection, config.validate());
    config.disallowed = &.{};
    config.set(.P003, true);
    config.selections = &.{.{ .rule = .P003, .level = .gate }};
    config.function_exceptions = &.{.{ .function = "missing", .lines = 120, .reason = "old reviewed boundary" }};
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "policy", .bytes = "pub fn live() void {}" }}, &.{}, .{});
    defer project.deinit();
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expect(!report.complete);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: incomplete policy has no invented finding.
}

test "G2 complete cast inventory includes boolean and volatile conversion reasons" {
    try check(.P001, "pub fn f(b: bool) u1 { return @intFromBool(b); }", 1);
    try check(.P001, "pub fn f(p: *volatile u8) *u8 { return @volatileCast(p); }", 1);
    try check(.P001, "pub fn f(b: bool) u1 { return @intFromBool(b); } // safe: bool conversion yields exactly zero or one\n", 0);
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "migration", .bytes = "pub fn f(b: bool) u1 { return @intFromBool(b); }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.P001, true);
    config.casts = .pointer;
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: explicit narrower migration selection.
}

test "private import references through reflection strings preserve declaration identity" {
    try check(.Z013, "const Self = @This(); const dep = @import(\"dep\"); pub fn run() void { _ = @field(Self, \"dep\"); }", 0);
    try check(.Z013, "const Self = @This(); const dep = @import(\"dep\"); pub fn run() void { _ = @hasDecl(Self, \"dep\"); }", 0);
    try check(.Z013, "const dep = @import(\"dep\"); const Other = struct { pub const dep = 1; }; pub fn run() void { _ = @field(Other, \"dep\"); }", 1);
}

test "private import gates retain required dynamic reflection uncertainty" {
    const sources = [_][]const u8{
        "const dep = @import(\"dep\"); pub fn run(comptime T: type) void { _ = @field(T, \"dep\"); }",
        "const Self = @This(); const dep = @import(\"dep\"); pub fn run(name: []const u8) void { _ = @field(Self, name); }",
    };
    for (sources) |bytes| {
        var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = bytes }}, &.{}, .{});
        defer project.deinit();
        var report = try glint.runConfigured(std.testing.allocator, &project, .{ .enabled = @splat(false), .selections = &.{.{ .rule = .Z013, .level = .gate }} }, .{});
        defer report.deinit();
        try std.testing.expect(!report.complete);
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: unknown reflection cannot support a dead-import allegation.
    }
}
