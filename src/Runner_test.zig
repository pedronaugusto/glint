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
    }, &.{.{ .from = @fromBackingInt(0), .spelling = "dep", .target = @fromBackingInt(1) }}, .{}); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
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
    }, &.{.{ .from = @fromBackingInt(0), .target = @fromBackingInt(1), .spelling = "std" }}, .{}); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
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
    try std.testing.expect(!(@as(glint.Config, .{})).has(.Z012));
    try std.testing.expect(!(@as(glint.Config, .{})).has(.Z026));
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "policy", .bytes = "const Hidden = struct {};\n// glint-ignore: Z012 -- inference-only factory\npub fn create() Hidden { return .{}; }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z012, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: expected count fits usize.
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: expected count fits usize.
}
