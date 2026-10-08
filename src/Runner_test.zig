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
    }, &.{.{ .from = @fromBackingInt(0), .spelling = "dep", .target = @fromBackingInt(1) }}, .{}); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z011, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 7), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
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

test "compatibility Z027 instance static access excludes fields and unknown receivers" {
    try check(.Z027, "const S = struct { x: u8, const constant = 1; }; pub fn f(s: S) void { _ = s.constant; _ = s.x; }", 1);
    try check(.Z027, "const S = struct { const constant = 1; }; pub fn f() void { _ = S.constant; }", 0);
}

test "compatibility Z029 uses contextual types and emits each cast once" {
    try check(.Z029, "fn g(x: u8) void { _ = x; } pub fn f() void { g(@as(u8, 1)); }", 1);
    try check(.Z029, "const S = struct { x: u8 }; const s = S{ .x = @as(u8, 1) }; const a = [1]u8{ @as(u8, 1) };", 2);
    try check(.Z029, "fn g(x: u16) void { _ = x; } pub fn f() void { g(@as(u8, 1)); }", 0);
}

test "compatibility Z030 is deinit poisoning hygiene, including cleanup and destruction" {
    try check(.Z030, "const S = struct { pub fn deinit(self: *S) void { _ = self; } };", 1);
    try check(.Z030, "const S = struct { pub fn deinit(self: *S) void { self.* = undefined; } };", 0);
    try check(.Z030, "const S = struct { pub fn deinit(self: *S, early: bool) void { if (early) return; self.* = undefined; } };", 1);
    try check(.Z030, "const S = struct { pub fn deinit(self: *S, early: bool) void { defer self.* = undefined; if (early) return; } };", 0);
    try check(.Z030, "const A = struct { fn destroy(_: A, _: *S) void {} }; const S = struct { pub fn deinit(self: *S, a: A) void { a.destroy(self); } };", 0);
    try check(.Z030, "const A = struct { fn destroy(_: A, _: *S) void {} }; const S = struct { pub fn deinit(self: *S, a: A) void { defer self.* = undefined; a.destroy(self); } };", 1);
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

test "compatibility unknown receiver and callee record uncertainty without invented facts" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const Self = @import(\"unmapped\").S; pub fn f(self: *Self, comptime T: type) void { _ = self; _ = T; @import(\"unmapped\").old(); }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z011, true);
    config.set(.Z023, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
    var unknown_callee = false;
    var unknown_receiver = false;
    for (report.coverage) |coverage| {
        if (coverage.rule == .Z011) unknown_callee = true;
        if (coverage.rule == .Z023) unknown_receiver = true;
    }
    try std.testing.expect(unknown_callee and unknown_receiver);
}

test "compatibility Z030 inherited branch destroy and poison order contrasts" {
    try check(.Z030, "const A = struct { fn destroy(_: A, _: *S) void {} }; const S = struct { pub fn deinit(self: *S, a: A, flag: bool) void { if (flag) { a.destroy(self); return; } self.* = undefined; } };", 0);
    try check(.Z030, "const A = struct { fn destroy(_: A, _: *S) void {} }; const S = struct { pub fn deinit(self: *S, a: A, flag: bool) void { if (flag) a.destroy(self); self.* = undefined; } };", 1);
    try check(.Z030, "const A = struct { fn destroy(_: A, _: *S) void {} }; const S = struct { pub fn deinit(self: *S, a: A) void { self.* = undefined; a.destroy(self); } };", 0);
    try check(.Z030, "const S = struct { pub fn deinit(self: *S, early: bool) void { if (early) { self.* = undefined; return; } self.* = undefined; } };", 0);
}

test "compatibility suppression rejects multiple distinct binding sites" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "const a = @import(\"a\"); const b = @import(\"b\"); // glint-ignore: Z013 -- one site only\n" }}, &.{}, .{});
    defer project.deinit();
    try std.testing.expectError(error.AmbiguousSuppression, glint.run(std.testing.allocator, &project, .{}));
}

test "compatibility deprecation resolves escaped member identity" {
    try check(.Z011, "const S = struct {\n /// Deprecated: use fresh.\n pub fn @\"old name\"() void {} }; pub fn run() void { S.@\"old name\"(); }", 1);
}

test "compatibility function-pointer parameter labels cannot shadow fields or imports" {
    try check(.Z027, "const S = struct { context: usize, call: *const fn (context: usize) void, pub fn f(self: S) void { self.call(self.context); } };", 0);
    try check(.Z013, "const dep = @import(\"dep\"); const S = struct { call: *const fn (dep: u8) void, pub fn f(self: S) void { self.call(dep.value); } };", 0);
}

test "compatibility Z010 needs a known literal context and keeps generic explicit types" {
    try check(.Z010, "const S = struct {}; fn g(x: anytype) void { _ = x; } pub fn f() void { g(S{}); }", 0);
    try check(.Z010, "const S = struct {}; fn g(x: S) void { _ = x; } pub fn f() void { g(S{}); }", 1);
}

test "compatibility public signature retains imported alias provenance" {
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "const d = @import(\"dep\"); const Alias = d.Errors; pub fn f() Alias!void {}" },
        .{ .name = "dep", .selected = false, .bytes = "pub const Errors = error{Bad};" },
    }, &.{.{ .from = @fromBackingInt(0), .target = @fromBackingInt(1), .spelling = "dep" }}, .{}); // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.Z015, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: explicit types represent bounded fixture/source indexes; enum identities belong to validated frozen tables.
}

test "compatibility Z027 excludes resolved function aliases used as methods" {
    try check(.Z027, "const S = struct { pub const read = readImpl; }; fn readImpl(_: S) void {} pub fn f(s: S) void { s.read(); }", 0);
}
