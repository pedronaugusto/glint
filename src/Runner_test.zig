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
    try std.testing.expectEqualStrings("Z013", report.stale[0].name);
    try std.testing.expectEqual(@as(u32, 1), report.stale[0].span.line); // safe: explicit compile-time type selection; the value is representable in that type.
    // A rule that does not run shows nothing about its suppressions.
    var unjudged = try glint.run(std.testing.allocator, &project, .{ .strict_suppressions = true, .enabled = @splat(false) });
    defer unjudged.deinit();
    try std.testing.expectEqual(@as(usize, 0), unjudged.stale_suppressions); // safe: explicit compile-time type selection; the value is representable in that type.
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

test "review Z006 reads a type built from field types as a type, and a value of one as a value" {
    try check(.Z006, "pub const Built = @Struct(.auto, null, &.{\"a\"}, &.{u8}, &@splat(.{})); pub const Pair = @Tuple(&.{ u8, u16 });", 0);
    try check(.Z006, "const Built = @Struct(.auto, null, &.{\"a\"}, &.{u8}, &@splat(.{})); pub const badValue: Built = undefined;", 1);
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
    // A discarded error is a result nobody read: a correctness finding.
    try std.testing.expectEqual(glint.RuleGroup.correctness, glint.Rule.Z026.group());
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

test "D001 counts every spelling of a private name in its file as a use" {
    try check(.D001, "fn unused() void {} pub fn live() void {}", 1);
    try check(.D001, "const S = struct { fn read(self: S) u8 { _ = self; return 1; } }; pub fn live(s: S) u8 { return s.read(); }", 0);
    try check(.D001, "const S = struct { const needed = 1; }; pub fn live() void { _ = @field(S, \"needed\"); }", 0);
    try check(.D001, "fn retained() void {}\n// glint-ignore: D001 -- deliberate fixture declaration tests unused-name reporting\nfn unused() void {}\npub fn live() void { retained(); }", 0);
    // A declaration literal names the declaration through its result type.
    try check(.D001, "const S = struct { x: u8, const empty: S = .{ .x = 0 }; }; pub fn live() u8 { const s: S = .empty; return s.x; }", 0);
    // A use only tests make is a use.
    try check(.D001, "fn helper() u8 { return 1; } test { _ = helper(); }", 0);
    try check(.D001, "const unknown = @import(\"external\"); fn used() void {} pub fn live() void { unknown.f(used); }", 0);
}

test "D001 reports what only the declaration itself or a field of that name names" {
    // A std hook cannot call a private method: it is not marked pub to another file.
    try check(.D001, "pub const S = struct { fn format(self: S) void { _ = self; } };", 1);
    try check(.D001, "fn Box(comptime T: type) type { return struct { value: T }; }", 1);
    try check(.D001, "fn walk(n: u8) u8 { return if (n == 0) 0 else walk(n - 1); } pub fn live() void {}", 1);
    // A struct literal's field name is a field, never the declaration.
    try check(.D001, "const width = 3; pub const S = struct { width: u8 = 0 }; pub fn live() S { return .{ .width = 1 }; }", 1);
    // An unknown import leaves the rest of the file decided.
    try check(.D001, "const unknown = @import(\"external\"); fn unused() void {} pub fn live() void { unknown.f(); }", 1);
    // A dead container is the finding, not each declaration inside it.
    try check(.D001, "pub const Outer = struct { const Inner = struct { fn format() void {} const x = 1; }; };", 1);
    // A lexical reference resolves to its own declaration, so a same-named one elsewhere stays dead.
    try check(.D001, "fn helper() u8 { return 1; } const S = struct { fn helper() u8 { return 2; } }; pub fn live() u8 { return helper(); }", 1);
}

test "D001 reads a computed @field through its receiver and withholds an unresolved one" {
    try check(.D001, "const S = struct { const needed = 1; }; pub fn live(name: []const u8) void { _ = @field(S, name); }", 0);
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture", .bytes = "fn unused() void {} pub fn live(x: anytype, comptime name: []const u8) void { _ = @field(x, name); }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.D001, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: the unresolved receiver withholds the file.
    var withheld = false;
    for (report.coverage) |item| if (item.rule) |rule| {
        if (rule == .D001 and item.reason == .unresolved) withheld = true;
    };
    try std.testing.expect(withheld);
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

test "G2 disallowed policy follows qualified declaration identity and aliases" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "policy.zig", .bytes = "const A = struct { fn raw() void {} }; const B = struct { fn raw() void {} }; const alias = A.raw; pub fn run() void { alias(); B.raw(); }" }}, &.{}, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(.P006, true);
    config.disallowed = &.{.{ .source = "policy.zig", .declaration = "A.raw", .reason = "this project requires the guarded API", .replacement = "checked" }};
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    // The alias is made where it spells A.raw; its call and B.raw reach no governed declaration.
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: exact fixture identity uses.
    try std.testing.expect(report.complete);
    config.disallowed = &.{.{ .source = "missing.zig", .declaration = "A.raw", .reason = "requires guarded API", .replacement = "checked" }};
    config.selections = &.{.{ .rule = .P006, .level = .gate }};
    var missing = try glint.run(std.testing.allocator, &project, config);
    defer missing.deinit();
    try std.testing.expect(!missing.complete);
    try std.testing.expectEqual(@as(usize, 0), missing.diagnostics.len); // safe: no invented missing declaration.
}

/// A program, a `lib` module standing for std, and its per-target namespace.
fn ownershipRun(program: []const u8, disallowed: []const glint.Config.Disallowed) !glint.Report {
    return ownershipRunIn(program, "", disallowed);
}

/// As `ownershipRun`, the program a file of `package`.
fn ownershipRunIn(program: []const u8, package: []const u8, disallowed: []const glint.Config.Disallowed) !glint.Report {
    const P = glint.Project;
    const inputs = [_]P.Input{
        .{ .name = "program.zig", .bytes = program, .package = package },
        .{ .name = "lib.zig", .bytes =
        \\pub const posix = @import("posix.zig");
        \\pub const c = @import("c.zig");
        \\pub const File = struct { handle: i32, pub fn sync(f: File) void { _ = f; } pub fn close(f: File) void { _ = f; } };
        , .selected = false },
        .{ .name = "posix.zig", .bytes = "pub fn fdatasync(fd: i32) void { _ = fd; }\npub fn read(fd: i32) void { _ = fd; }", .selected = false },
        .{ .name = "c.zig", .bytes =
        \\pub extern "c" fn fsync(fd: c_int) c_int;
        \\pub const F = switch (@import("builtin").os.tag) { .macos => struct { pub const FULLFSYNC = 51; pub const GETFL = 3; }, else => struct { pub const GETFL = 3; } };
        , .selected = false },
    };
    const imports = [_]P.Import{
        .{ .from = P.FileId.fromRaw(0), .spelling = "lib", .target = P.FileId.fromRaw(1) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "posix.zig", .target = P.FileId.fromRaw(2) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "c.zig", .target = P.FileId.fromRaw(3) },
    };
    var project = try P.init(std.testing.allocator, &inputs, &imports, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.selections = &.{.{ .rule = .P006, .level = .gate }};
    config.disallowed = disallowed;
    return glint.run(std.testing.allocator, &project, config);
}

const durability = [_]glint.Config.Disallowed{
    .{ .source = "lib", .declaration = "posix.fdatasync", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile" },
    .{ .source = "lib", .declaration = "c.fsync", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile" },
    .{ .source = "lib", .declaration = "c.F.FULLFSYNC", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile" },
    .{ .source = "lib", .declaration = "File.sync", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile", .scope = .production },
    .{ .declaration = "FlushFileBuffers", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile" },
};

test "P006 governs a module's declarations by what each reference reaches" {
    var report = try ownershipRun(
        \\const lib = @import("lib");
        \\const posix = lib.posix;
        \\const sync = posix.fdatasync;
        \\pub fn a(fd: i32) void { posix.fdatasync(fd); posix.read(fd); sync(fd); }
        \\pub fn b(f: lib.File) void { f.sync(); f.close(); }
        \\pub fn c(fd: i32) void { _ = lib.c.fsync(fd); _ = lib.c.F.FULLFSYNC; _ = lib.c.F.GETFL; }
        \\pub fn d() void { @field(lib.posix, "fdatasync")(0); }
    , &durability);
    defer report.deinit();
    try std.testing.expect(report.complete);
    // fdatasync called, where the alias is made and through `@field`; File.sync, c.fsync, F.FULLFSYNC.
    try std.testing.expectEqual(@as(usize, 6), report.diagnostics.len); // safe: fixture sites counted by hand.
}

test "P006 binds an external symbol, the program's own declaration of it too" {
    var report = try ownershipRun(
        \\extern "c" fn fsync(fd: c_int) c_int;
        \\extern "kernel32" fn FlushFileBuffers(handle: *anyopaque) c_int;
        \\fn flush() void {}
        \\pub fn a(h: *anyopaque) void { _ = fsync(0); _ = FlushFileBuffers(h); flush(); }
    , &durability);
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: fixture sites counted by hand.
}

test "P006 leaves a governed name it cannot resolve undecided, and other names alone" {
    var report = try ownershipRun(
        \\pub const Kind = enum { sync, close };
        \\pub const Op = union(enum) { sync, read: u32 };
        \\pub fn a(f: anytype) void { f.sync(); f.flush(); }
    , &durability);
    defer report.deinit();
    try std.testing.expect(!report.complete);
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: nothing resolved.
    var undecided: usize = 0;
    for (report.coverage) |note| if (note.rule != null and note.rule.? == .P006) {
        undecided += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), undecided); // safe: only `sync` is a governed name.
}

test "P006 production scope leaves test code out" {
    var report = try ownershipRun(
        \\const lib = @import("lib");
        \\test { const f: lib.File = .{ .handle = 0 }; f.sync(); lib.posix.fdatasync(0); }
    , &durability);
    defer report.deinit();
    // File.sync is governed in production only; fdatasync everywhere.
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: fixture sites counted by hand.
}

test "P006 leaves an entry's owning packages alone, and only them" {
    const owned = [_]glint.Config.Disallowed{
        .{ .source = "lib", .declaration = "posix.fdatasync", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile", .owners = &.{ "airlock", "reactor" } },
        .{ .declaration = "fsync", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile", .owners = &.{"airlock"} },
    };
    const program =
        \\const lib = @import("lib");
        \\extern "c" fn fsync(fd: c_int) c_int;
        \\pub fn a() void { lib.posix.fdatasync(0); _ = fsync(0); }
    ;
    inline for (.{ .{ "airlock", 0 }, .{ "reactor", 1 }, .{ "shakedown", 2 }, .{ "", 2 } }) |case| {
        var report = try ownershipRunIn(program, case[0], &owned);
        defer report.deinit();
        try std.testing.expect(report.complete);
        try std.testing.expectEqual(@as(usize, case[1]), report.diagnostics.len); // safe: fixture sites counted by hand.
    }
}

test "P006 configuration needs a symbol without dots, or a source and a path" {
    var config = glint.Config.none();
    config.disallowed = &.{.{ .declaration = "c.fsync", .reason = "durability", .replacement = "airlock" }};
    try std.testing.expectError(error.InvalidSelection, config.validate());
    config.disallowed = &.{.{ .source = " ", .declaration = "fsync", .reason = "durability", .replacement = "airlock" }};
    try std.testing.expectError(error.InvalidSelection, config.validate());
    config.disallowed = &.{.{ .declaration = "fsync", .reason = "durability", .replacement = "airlock", .owners = &.{" "} }};
    try std.testing.expectError(error.InvalidSelection, config.validate());
    config.disallowed = &.{.{ .declaration = "fsync", .reason = "durability", .replacement = "airlock", .owners = &.{"airlock"} }};
    try config.validate();
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

test "metrics count assertion calls by the declaration their callee resolves to" {
    const P = glint.Project;
    const program =
        \\const std = @import("std");
        \\const aegis = @import("aegis");
        \\const assert = std.debug.assert;
        \\const contract = aegis.assert;
        \\fn assertLocal(ok: bool) void { _ = ok; }
        \\pub fn a(x: u8) u8 { assert(x < 9); contract.pre(x > 0, "positive"); return x; }
        \\pub fn b(x: u8) u8 { std.debug.assert(x != 3); return if (x == 1) contract.never("one") else x; }
        \\pub fn c(x: u8) void { assertLocal(x == 0); }
        \\pub fn d(m: anytype) void { m.invariant(true, "unknown"); }
        \\test { assert(true); }
    ;
    const inputs = [_]P.Input{
        .{ .name = "program.zig", .bytes = program },
        .{ .name = "std.zig", .bytes = "pub const debug = @import(\"debug.zig\");", .selected = false },
        .{ .name = "debug.zig", .bytes = "pub fn assert(ok: bool) void { if (!ok) unreachable; }", .selected = false },
        .{ .name = "aegis.zig", .bytes = "pub const assert = @import(\"assert.zig\");", .selected = false },
        .{ .name = "assert.zig", .bytes = "pub fn pre(ok: bool, comptime m: []const u8) void { if (!ok) @panic(m); }\npub inline fn never(comptime m: []const u8) noreturn { @panic(m); }", .selected = false },
    };
    const imports = [_]P.Import{
        .{ .from = P.FileId.fromRaw(0), .spelling = "std", .target = P.FileId.fromRaw(1) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "debug.zig", .target = P.FileId.fromRaw(2) },
        .{ .from = P.FileId.fromRaw(0), .spelling = "aegis", .target = P.FileId.fromRaw(3) },
        .{ .from = P.FileId.fromRaw(3), .spelling = "assert.zig", .target = P.FileId.fromRaw(4) },
    };
    var project = try P.init(std.testing.allocator, &inputs, &imports, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.metrics = true;
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    const metrics = report.metrics.?;
    try std.testing.expectEqual(@as(usize, 1), metrics.files.len); // safe: one selected file.
    const t = metrics.total;
    try std.testing.expectEqual(@as(u32, 5), t.functions); // safe: expected count fits u32.
    try std.testing.expectEqual(@as(u32, 2), t.asserted); // safe: expected count fits u32.
    try std.testing.expectEqual(@as(u32, 3), t.assertions[@backingInt(glint.Report.Metrics.Kind.std_assert)]); // safe: a kind indexes its own count table.
    try std.testing.expectEqual(@as(u32, 1), t.assertions[@backingInt(glint.Report.Metrics.Kind.pre)]); // safe: a kind indexes its own count table.
    try std.testing.expectEqual(@as(u32, 1), t.assertions[@backingInt(glint.Report.Metrics.Kind.never)]); // safe: a kind indexes its own count table.
    try std.testing.expectEqual(@as(u32, 1), t.unresolved); // safe: expected count fits u32.
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try report.write(&text.writer, &project, .text);
    try std.testing.expect(std.mem.find(u8, text.written(), "metrics: 1 files, 5 functions, 2 with an assertion, 5 assertions (std.debug.assert 3, aegis.assert.pre 1, aegis.assert.never 1), 1 assertion-like calls unresolved\n") != null);
}

test "P006 decides an unresolved receiver by what Zig allows at the site" {
    // A configuration value named like a sync call, read from a generic database and used as
    // a receiver, and a method given an enum literal where the governed one takes a struct.
    var report = try ownershipRun(
        \\pub fn a(db: anytype) void { const fsync = db.settings().fsync; fsync.sync(.pack); }
        \\pub fn b(db: anytype) void { db.file().sync(); }
    , &durability);
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: nothing resolved.
    var undecided: usize = 0;
    for (report.coverage) |note| if (note.rule != null and note.rule.? == .P006) {
        undecided += 1;
    };
    // `db.file().sync()` may be File.sync: it stays undecided.
    try std.testing.expectEqual(@as(usize, 1), undecided); // safe: one site cannot be refuted.
}

test "E001 finds a pointer into the frame carried out of the call" {
    // A slice of a local array, returned.
    try check(.E001, "pub fn f(n: usize) []u8 { var buf: [16]u8 = undefined; buf[0] = 1; return buf[0..n]; }", 1);
    // Through a const alias, and in a returned struct literal.
    try check(.E001, "pub fn f() *u32 { var x: u32 = 1; x += 1; const out = &x; return out; }", 1);
    try check(.E001, "const R = struct { s: []u8 }; pub fn f(n: usize) R { var buf: [8]u8 = undefined; buf[0] = 1; return .{ .s = buf[0..n] }; }", 1);
    // A field of a local value, through a parameter and into a container's variable.
    try check(.E001, "const S = struct { a: u32 = 0 }; const T = struct { p: *u32 }; pub fn f(t: *T) void { var s: S = .{}; s.a = 1; t.p = &s.a; }", 1);
    try check(.E001, "var last: ?*u32 = null; pub fn f() void { var x: u32 = 1; x += 1; last = &x; }", 1);
}

test "E001 leaves static storage, pointers, copies and undone stores alone" {
    // A const is comptime-known and static; a comptime frame is comptime memory.
    try check(.E001, "pub fn f() []const u8 { const table = [_]u8{ 1, 2 }; return table[0..]; }", 0);
    try check(.E001, "pub fn f() []const u8 { comptime { var buf: [2]u8 = .{ 1, 2 }; buf[0] = 3; const out = buf; return &out; } }", 0);
    try check(.E001, "pub fn Make(comptime n: usize) type { var x: [n]u8 = undefined; x[0] = 1; _ = &x; return struct {}; }", 0);
    // A local that is a pointer or a slice: its fields and elements are elsewhere.
    try check(.E001, "const N = struct { v: u32 }; pub fn f(head: *N) *u32 { var node: *N = head; node.v += 1; return &node.v; }", 0);
    try check(.E001, "pub fn f(items: []u8) []u8 { var s: []u8 = items; s = s[1..]; return s[0..1]; }", 0);
    // A copy, not a pointer; a store a defer undoes.
    try check(.E001, "pub fn f() [4]u8 { var buf: [4]u8 = undefined; buf[0] = 1; return buf; }", 0);
    try check(.E001, "const T = struct { cur: ?*u32 = null }; pub fn f(t: *T) void { var x: u32 = 1; x += 1; t.cur = &x; defer t.cur = null; }", 0);
    // A store into another local outlives nothing.
    try check(.E001, "pub fn f() u32 { var x: u32 = 1; var p: *u32 = undefined; p = &x; p.* += 1; return x; }", 0);
}

test "E001 leaves an intrusive waiter the function unlinks before it returns" {
    try check(.E001,
        \\const W = struct { next: ?*W = null };
        \\const Q = struct { first: ?*W = null };
        \\pub fn wait(q: *Q) void {
        \\    var waiter: W = .{ .next = q.first };
        \\    q.first = &waiter;
        \\    defer {
        \\        var link = &q.first;
        \\        while (link.* != &waiter) link = &link.*.?.next;
        \\        link.* = waiter.next;
        \\    }
        \\}
    , 0);
}

test "review Z006 accepts a name a generic reads on its type parameter that an outside type declares" {
    const outside = "pub const Edwards = struct { pub const basePoint: Edwards = .{}; };";
    const own = "const dep = @import(\"dep\");\npub const Point = struct { pub const basePoint: Point = .{}; pub const otherName: Point = .{}; };\nfn table(comptime P: type) P { return P.basePoint; }\npub fn f() void { _ = table(Point); _ = table(dep.Edwards); }";
    for ([_]bool{ true, false }) |generic| {
        const source = if (generic) own else "const dep = @import(\"dep\");\npub const Point = struct { pub const basePoint: Point = .{}; pub const otherName: Point = .{}; };\npub fn f() void { _ = dep; }";
        var project = try glint.Project.init(std.testing.allocator, &.{ .{ .name = "fixture", .stem = "Fixture", .bytes = source }, .{ .name = "dep", .stem = "Dep", .bytes = outside, .selected = false } }, &.{.{ .from = .fromRaw(0), .spelling = "dep", .target = .fromRaw(1) }}, .{});
        defer project.deinit();
        var config = glint.Config.none();
        config.set(.Z006, true);
        var report = try glint.run(std.testing.allocator, &project, config);
        defer report.deinit();
        // `otherName` no outside type declares; `basePoint` only where a generic reads it.
        try std.testing.expectEqual(@as(usize, if (generic) 1 else 2), report.diagnostics.len); // safe: fixture counts are representable.
    }
}

/// `rule` over `source` beside a small std (an array list and a hash map whose storage their
/// borrows point into): its findings, and its undecided sites.
fn checkWithStd(rule: glint.Rule, source: []const u8, expected: usize, undecided: usize) !void {
    const std_root =
        \\pub const array_list = @import("array_list.zig");
        \\pub fn ArrayList(comptime T: type) type { return array_list.Aligned(T, null); }
        \\pub const AutoHashMapUnmanaged = @import("hash_map.zig").AutoHashMapUnmanaged;
    ;
    const list =
        \\pub fn Aligned(comptime T: type, comptime alignment: ?u8) type {
        \\    _ = alignment;
        \\    return struct {
        \\        const Self = @This();
        \\        items: []T = &.{},
        \\        capacity: usize = 0,
        \\        pub fn append(self: *Self, gpa: anytype, item: T) !void { _ = .{ self, gpa, item }; }
        \\        pub fn appendAssumeCapacity(self: *Self, item: T) void { _ = .{ self, item }; }
        \\        pub fn addOne(self: *Self, gpa: anytype) !*T { _ = gpa; return &self.items[0]; }
        \\        pub fn ensureTotalCapacity(self: *Self, gpa: anytype, n: usize) !void { _ = .{ self, gpa, n }; }
        \\        pub fn deinit(self: *Self, gpa: anytype) void { _ = .{ self, gpa }; }
        \\        pub fn toOwnedSlice(self: *Self, gpa: anytype) ![]T { _ = gpa; return self.items; }
        \\    };
        \\}
    ;
    const map =
        \\pub fn AutoHashMapUnmanaged(comptime K: type, comptime V: type) type {
        \\    return struct {
        \\        const Self = @This();
        \\        values_: []V = &.{},
        \\        pub fn getPtr(self: *Self, key: K) ?*V { _ = key; return &self.values_[0]; }
        \\        pub fn put(self: *Self, gpa: anytype, key: K, value: V) !void { _ = .{ self, gpa, key, value }; }
        \\    };
        \\}
    ;
    const file = glint.Project.FileId.fromRaw;
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "fixture", .stem = "Fixture", .bytes = source },
        .{ .name = "std/std.zig", .bytes = std_root, .selected = false },
        .{ .name = "std/array_list.zig", .bytes = list, .selected = false },
        .{ .name = "std/hash_map.zig", .bytes = map, .selected = false },
    }, &.{
        .{ .from = file(0), .spelling = "std", .target = file(1) },
        .{ .from = file(1), .spelling = "array_list.zig", .target = file(2) },
        .{ .from = file(1), .spelling = "hash_map.zig", .target = file(3) },
    }, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.set(rule, true);
    var report = try glint.run(std.testing.allocator, &project, config);
    defer report.deinit();
    try std.testing.expectEqual(expected, report.diagnostics.len);
    var sites: usize = 0;
    for (report.coverage) |entry| {
        if (entry.rule == rule) sites += 1;
    }
    try std.testing.expectEqual(undecided, sites);
}

test "E002 finds a borrow of a list's or map's storage used after an operation that may move it" {
    const head = "const std = @import(\"std\");\nconst List = std.ArrayList(u32);\nconst Map = std.AutoHashMapUnmanaged(u32, u32);\n";
    // An element's address, the items, the element `addOne` gives, a map's value pointer.
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) !u32 { const first = &list.items[0]; try list.append(gpa, 1); return first.*; }", 1, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) !u32 { const all = list.items; try list.append(gpa, 2); return all[0]; }", 1, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) !void { const slot = try list.addOne(gpa); try list.append(gpa, 1); slot.* = 3; }", 1, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, map: *Map) !void { const p = map.getPtr(1) orelse return; try map.put(gpa, 2, 3); p.* += 1; }", 1, 0);
    // A field of the caller's, and a loop that grows it before the next pass reads the borrow.
    try checkWithStd(.E002, head ++ "const S = struct { list: List };\npub fn f(gpa: u8, s: *S) !u32 { const first = &s.list.items[0]; try s.list.append(gpa, 1); return first.*; }", 1, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) !void { const first = &list.items[0]; for (0..3) |_| { first.* += 1; try list.append(gpa, 1); } }", 1, 0);
}

test "E002 leaves copies, borrows taken again, capacity reserved first, other containers and exits alone" {
    const head = "const std = @import(\"std\");\nconst List = std.ArrayList(u32);\n";
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) !u32 { const first = list.items[0]; try list.append(gpa, 1); return first; }", 0, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) !u32 { var all = list.items; try list.append(gpa, 1); all = list.items; return all[0]; }", 0, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) !u32 { try list.ensureTotalCapacity(gpa, 4); const first = &list.items[0]; list.appendAssumeCapacity(1); return first.*; }", 0, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List, other: *List) !u32 { const first = &list.items[0]; try other.append(gpa, 1); return first.*; }", 0, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List, n: u32) !u32 { const first = &list.items[0]; if (n > 3) { try list.append(gpa, 1); return 0; } return first.*; }", 0, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List) u32 { defer list.deinit(gpa); const all = list.items; return all[0]; }", 0, 0);
    try checkWithStd(.E002, head ++ "pub fn f(gpa: u8, list: *List, done: bool) ![]u32 { const all = list.items; if (done) return list.toOwnedSlice(gpa); return all; }", 0, 0);
    // A container whose type does not resolve: undecided.
    try checkWithStd(.E002, head ++ "pub fn f(gpa: anytype, list: anytype) !u32 { const first = &list.items[0]; try list.append(gpa, 1); return first.*; }", 0, 1);
}
