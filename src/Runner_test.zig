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
    }, &.{.{ .from = 0, .spelling = "dep", .target = 1 }}, .{}); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
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
    }, &.{.{ .from = 0, .target = 1, .spelling = "std" }}, .{}); // safe: fixture constants and bounded output lengths fit the asserted integer widths.
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

test "each file's analysis has its own fact budget" {
    // A019 follows the pointer a parent is recovered from: facts each file's analysis spends.
    const source = "const W = struct { x: u32 };\nconst H = struct { n: u32, w: W };\nfn of(w: *W) *H {\n    return @fieldParentPtr(\"w\", w);\n}\npub fn run(h: *H) u32 {\n    return of(&h.w).n;\n}\n";
    const pack = glint.AegisPack;
    const selected: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.unsafe_set, .level = .report }} };
    var one = try glint.Project.init(std.testing.allocator, &.{.{ .name = "one", .bytes = source }}, &.{}, .{});
    defer one.deinit();
    // The least budget one file completes in.
    var config = selected;
    config.fact_budget = 1;
    while (config.fact_budget < 100_000) : (config.fact_budget += 1) {
        var report = try glint.runConfigured(std.testing.allocator, &one, config, .{ .project_rules = &pack.rules });
        defer report.deinit();
        if (report.complete) break;
    }
    try std.testing.expect(config.fact_budget > 1);
    // In a program of three such files, the first file's analysis pays for the scans of the
    // program it makes, which the later files' analyses reuse. A budget the run shared would
    // leave nothing for them; each has its own and completes in it.
    var three = try glint.Project.init(std.testing.allocator, &.{ .{ .name = "one", .bytes = source }, .{ .name = "two", .bytes = source }, .{ .name = "three", .bytes = source } }, &.{}, .{});
    defer three.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &three, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    for (report.coverage) |item| if (item.reason == .budget_exhausted) {
        try std.testing.expectEqual(three.sources[0].id, item.file);
    };
}

test "a rule whose flow facts are not solved within their budget is reported at each file that asks, never silently clean" {
    const source = "pub fn at(s: []const u8, i: usize) u8 {\n    return s[i];\n}\n";
    const pack = glint.AegisPack;
    var project = try glint.Project.init(std.testing.allocator, &.{ .{ .name = "one", .bytes = source }, .{ .name = "two", .bytes = source } }, &.{}, .{});
    defer project.deinit();
    var config: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = pack.untrusted_input, .level = .report }} };
    config.fact_budget = 1;
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &pack.rules });
    defer report.deinit();
    // No clean verdict: the run is incomplete, and each file's rule is reported unjudged.
    try std.testing.expect(!report.complete);
    var asked: usize = 0;
    for (report.coverage) |item| {
        if (item.reason == .budget_exhausted and item.rule != null and item.rule.? == pack.untrusted_input) asked += 1;
    }
    try std.testing.expectEqual(2, asked);
    // No finding is made of facts not solved.
    for (report.diagnostics) |diagnostic| try std.testing.expect(diagnostic.rule != pack.untrusted_input);
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
    // A member whose holder does not resolve may be each private import its own container
    // declares under that name, in every container: none is reported. Named through a known
    // container, the other is.
    const two = "const A = struct { const dep = @import(\"dep\"); }; const B = struct { const dep = @import(\"other\"); }; ";
    try check(.Z013, two ++ "pub fn f(x: anytype) void { _ = x.dep; }", 0);
    try check(.Z013, two ++ "pub fn f() void { _ = A.dep; }", 1);
}

test "Z034 finds operators Zig 0.18 refuses to order without parentheses, and leaves the orders it keeps" {
    // Bitwise operators mixed, arithmetic with bitwise, a product with a remainder, `and` with
    // `or`, `orelse` with arithmetic, a chained shift and a chained remainder.
    try check(.Z034,
        \\pub fn f(a: u32, b: u32, c: u32, p: bool, q: bool, r: bool, x: ?u32) void {
        \\    _ = a | b & c;
        \\    _ = a + b << 2;
        \\    _ = a * b % c;
        \\    _ = p and q or r;
        \\    _ = x orelse b + 1;
        \\    _ = a << 1 << 2;
        \\    _ = a % b % c;
        \\}
    , 7);
    try check(.Z034,
        \\pub fn f(a: u32, b: u32, c: u32, p: bool, q: bool, x: ?u32) void {
        \\    _ = a + b * c;
        \\    _ = a * b + c;
        \\    _ = a & b == c;
        \\    _ = a + b < c and p;
        \\    _ = (a | b) & c;
        \\    _ = a & b & c;
        \\    _ = x orelse 0;
        \\    _ = p or q or p;
        \\    _ = a - b - c;
        \\}
    , 0);
}

test "Z026 a test's refusal assertion is no discard, the same shape in production code is" {
    // A set with OutOfMemory: no refusal alone (Discards), so only the assertion's form is read here.
    const parse = "fn parse(b: []const u8) error{ OutOfMemory, Bad }!u8 { return if (b.len == 1) b[0] else error.Bad; }\n";
    // In a test, the success branch leaves by an error: the error branch is the assertion's pass.
    try check(.Z026, parse ++ "test \"refused\" { if (parse(\"ab\")) |_| return error.TestUnexpectedResult else |_| {} }", 0);
    try check(.Z026, parse ++ "test \"refused\" { if (parse(\"ab\")) |_| { @panic(\"read\"); } else |_| {} }", 0);
    try check(.Z026, parse ++ "test \"refused\" { if (parse(\"ab\")) |v| { _ = v; return error.TestUnexpectedResult; } else |_| {} }", 0);
    // The same shape in production code: a failure read as an answer, still a site.
    try check(.Z026, parse ++ "pub fn present(b: []const u8) error{Missing}!void { if (parse(b)) |_| return error.Missing else |_| {} }", 1);
    // A test's success branch that goes on, or may leave another way, answers nothing.
    try check(.Z026, parse ++ "test \"used\" { var n: u8 = 0; if (parse(\"ab\")) |v| n = v else |_| {} try @import(\"std\").testing.expect(n == 0); }", 1);
    try check(.Z026, parse ++ "test \"looped\" { for (0..2) |i| { if (parse(\"ab\")) |_| { if (i == 0) continue; return error.TestUnexpectedResult; } else |_| {} } }", 1);
    // A `catch`, in a test too, stays a site.
    try check(.Z026, parse ++ "test \"caught\" { _ = parse(\"ab\") catch {}; }", 1);
}

test "Z026 a refusal assertion in a file only tests reach is no discard" {
    const helper = "fn parse(b: []const u8) error{ OutOfMemory, Bad }!u8 { return if (b.len == 1) b[0] else error.Bad; }\npub fn refused() !void { if (parse(\"ab\")) |_| return error.TestUnexpectedResult else |_| {} }\n";
    const cases = [_]struct { root: []const u8, expected: usize }{
        // Imported only from a test block: test code.
        .{ .root = "test { _ = @import(\"helper.zig\"); }", .expected = 0 },
        // The same import spelled with an escape: read as its value, as Facts reads it.
        .{ .root = "test { _ = @import(\"helper\\x2ezig\"); }", .expected = 0 },
        // Imported by the program too: production code.
        .{ .root = "const helper = @import(\"helper.zig\"); pub fn run() !void { try helper.refused(); } test { _ = helper; }", .expected = 1 },
    };
    for (cases) |case| {
        var project = try glint.Project.init(std.testing.allocator, &.{
            .{ .name = "root", .bytes = case.root },
            .{ .name = "helper.zig", .bytes = helper },
        }, &.{.{ .from = 0, .spelling = "helper.zig", .target = 1 }}, .{});
        defer project.deinit();
        var config = glint.Config.none();
        config.set(.Z026, true);
        var report = try glint.run(std.testing.allocator, &project, config);
        defer report.deinit();
        try std.testing.expectEqual(case.expected, report.diagnostics.len);
        try std.testing.expect(report.complete);
    }
}

test "G2 Z026 family reason policy includes cleanup and distinguishes handled errors" {
    try check(.Z026, "fn fallible() error{Failure}!void {} pub fn f() void { fallible() catch {}; defer fallible() catch {}; }", 2);
    try check(.Z026, "fn fallible() error{Failure}!void {} pub fn f() void { fallible() catch { return; }; }", 0);
    try check(.Z026, "fn fallible() error{Failure}!void {}\npub fn f() void { fallible() catch {}; } // glint-ignore: Z026 -- best-effort cleanup; no recovery available\n", 0);
    try check(.Z026, "const text = \"catch {} // glint-ignore: Z026 -- fake\"; pub fn f() void { _ = text; }", 0);
    // A discarded error is a result nobody read: a correctness finding.
    try std.testing.expectEqual(glint.RuleGroup.correctness, glint.Rule.Z026.group());
}

/// A run of `rule` on `root`, which imports a fixture std whose `debug` has `assert` and `print`.
fn withStd(rule: glint.Rule, root: []const u8) !glint.Report {
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = root },
        .{ .name = "standard", .bytes = "pub const debug = struct { pub fn assert(ok: bool) void { _ = ok; } pub fn print(comptime f: []const u8, a: anytype) void { _ = f; _ = a; } };", .selected = false },
    }, &.{.{ .from = 0, .target = 1, .spelling = "std" }}, .{}); // safe: fixture constants fit the asserted integer widths.
    defer project.deinit();
    var config = glint.Config.none();
    config.set(rule, true);
    return glint.run(std.testing.allocator, &project, config);
}

test "Z016 reads std's assert by meaning: a choice of callees one of which is it, an unknown under its own rule" {
    // A mutable local holding std's assert in one path calls it.
    const chosen = "const std = @import(\"std\"); fn mine(ok: bool) void { _ = ok; } pub fn f(a: bool, b: bool, other: bool) void { var check: *const fn (bool) void = std.debug.assert; if (other) check = mine; check(a and b); }";
    var assert_choice = try withStd(.Z016, chosen);
    defer assert_choice.deinit();
    try std.testing.expectEqual(@as(usize, 1), assert_choice.diagnostics.len); // safe: expected count fits usize.
    const neither = "const std = @import(\"std\"); fn mine(ok: bool) void { _ = ok; } fn yours(ok: bool) void { _ = ok; } pub fn f(a: bool, b: bool, other: bool) void { var check: *const fn (bool) void = yours; if (other) check = mine; check(a and b); }";
    var no_assert = try withStd(.Z016, neither);
    defer no_assert.deinit();
    try std.testing.expectEqual(@as(usize, 0), no_assert.diagnostics.len); // safe: expected count fits usize.
    try std.testing.expect(no_assert.complete);
    // A callee that may be any function, named as std's assert is: undecided under Z016.
    var unknown = try withStd(.Z016, "pub fn f(a: bool, b: bool, g: anytype) void { g.assert(a and b); }");
    defer unknown.deinit();
    try std.testing.expectEqual(@as(usize, 0), unknown.diagnostics.len); // safe: expected count fits usize.
    var undecided: usize = 0;
    for (unknown.coverage) |item| if (item.rule) |rule| {
        try std.testing.expectEqual(glint.Rule.Z016, rule);
        undecided += 1;
    };
    try std.testing.expect(undecided != 0);
}

test "an import of Zig's own builtin is no file glint lacks; a missing one is" {
    const chosen = "const builtin = @import(\"builtin\"); pub const Hidden = if (builtin.is_test) struct { x: u8 } else struct { y: u8 }; pub fn make() Hidden { return undefined; }";
    for ([_]struct { []const u8, usize }{ .{ chosen, 0 }, .{ "const lib = @import(\"lib\"); pub fn f() void { _ = lib; }", 1 } }) |each| {
        var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "fixture", .bytes = each[0] }}, &.{}, .{});
        defer project.deinit();
        var config = glint.Config.none();
        config.set(.Z012, true);
        var report = try glint.run(std.testing.allocator, &project, config);
        defer report.deinit();
        try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: expected count fits usize.
        // The file notes of imports that do not resolve: no rule's, unresolved.
        var imports: usize = 0;
        for (report.coverage) |item| {
            if (item.rule == null and item.reason == .unresolved) imports += 1;
        }
        try std.testing.expectEqual(each[1], imports);
    }
}

test "Z012 judges the whole public surface: constants' types, reached fields, aliases of functions" {
    // A public constant's type, written or inferred, and a public alias of a private function.
    try check(.Z012, "const Hidden = struct { x: u8 }; pub const default: Hidden = .{ .x = 1 };", 1);
    try check(.Z012, "const Hidden = struct { x: u8 }; pub const default = Hidden{ .x = 1 };", 1);
    try check(.Z012, "pub const Hidden = struct { x: u8 }; pub const default = Hidden{ .x = 1 };", 0);
    try check(.Z012, "const Hidden = struct { x: u8 }; fn makeHidden() Hidden { return .{ .x = 1 }; } pub const make = makeHidden;", 1);
    try check(.Z012, "pub const Hidden = struct { x: u8 }; fn makeHidden() Hidden { return .{ .x = 1 }; } pub const make = makeHidden;", 0);
    // A field of a container the surface reaches; one nothing public reaches is not surface.
    try check(.Z012, "const Hidden = struct { x: u8 }; pub const Api = struct { inner: Hidden };", 1);
    try check(.Z012, "const Hidden = struct { x: u8 }; const Api = struct { inner: Hidden }; pub fn use() void { _ = Api; }", 0);
    // A container is held by the declaration around it, whatever expression writes it.
    try check(.Z012, "const Hidden = (struct { x: u8 }); pub fn make() Hidden { return .{ .x = 1 }; }", 1);
    try check(.Z012, "pub const Hidden = (struct { x: u8 }); pub fn make() Hidden { return .{ .x = 1 }; }", 0);
    // A type function's call written in a signature, with a value argument named by a private
    // declaration: a caller cannot spell the type.
    try check(.Z012, "pub fn Wrap(comptime g: fn () u8) type { return struct { pub fn get() u8 { return g(); } }; } fn helper() u8 { return 1; } pub fn make() Wrap(helper) { return .{}; }", 1);
    try check(.Z012, "pub fn Wrap(comptime g: fn () u8) type { return struct { pub fn get() u8 { return g(); } }; } pub fn helper() u8 { return 1; } pub fn make() Wrap(helper) { return .{}; }", 0);
    // The same call held by a public constant: the constant is the name a user spells, and a value
    // argument is read by its type, what of it comes back through the result.
    try check(.Z012, "pub fn Owned(comptime T: type, comptime cleanup: fn (*T) void) type { return struct { v: T, pub fn deinit(s: *@This()) void { cleanup(&s.v); } }; } fn closeIt(v: *u32) void { v.* = 0; } pub const File = Owned(u32, closeIt);", 0);
    try check(.Z012, "const Hidden = struct { x: u8 }; pub fn Wrap(comptime g: anytype) type { return struct { pub const get = g; }; } fn helper() Hidden { return .{ .x = 1 }; } pub const W = Wrap(helper);", 1);
    try check(.Z012, "pub fn Keep(comptime v: anytype) type { return struct { pub const value = v; }; } const Setting = struct { level: u32 }; const chosen: Setting = .{ .level = 1 }; pub const K = Keep(chosen);", 1);
    try check(.Z012, "pub fn Keep(comptime v: anytype) type { return struct { pub const value = v; }; } pub const Setting = struct { level: u32 }; const chosen: Setting = .{ .level = 1 }; pub const K = Keep(chosen);", 0);
    // Inside a held call alike: a literal's fields and a nested call's arguments are read by their type.
    try check(.Z012, "pub fn Keep(comptime v: anytype) type { return struct { pub const value = v; }; } const Setting = struct { level: u32 }; const chosen: Setting = .{ .level = 1 }; pub const K = Keep(.{ .v = chosen });", 1);
    try check(.Z012, "pub fn Keep(comptime v: anytype) type { return struct { pub const value = v; }; } pub const Setting = struct { level: u32 }; const chosen: Setting = .{ .level = 1 }; pub const K = Keep(.{ .v = chosen });", 0);
    try check(.Z012, "pub fn Keep(comptime v: anytype) type { return struct { pub const value = v; }; } pub fn Same(comptime v: anytype) @TypeOf(v) { return v; } const Setting = struct { level: u32 }; const chosen: Setting = .{ .level = 1 }; pub const K = Keep(Same(chosen));", 1);
    try check(.Z012, "pub fn Keep(comptime v: anytype) type { return struct { pub const value = v; }; } pub fn Same(comptime v: anytype) @TypeOf(v) { return v; } pub const Setting = struct { level: u32 }; const chosen: Setting = .{ .level = 1 }; pub const K = Keep(Same(chosen));", 0);
    // A call in a signature names what it takes at every level.
    try check(.Z012, "pub fn Keep(comptime v: anytype) type { return struct { pub const value = v; }; } pub const Setting = struct { level: u32 }; const chosen: Setting = .{ .level = 1 }; pub fn make() Keep(.{ .v = chosen }) { return undefined; }", 1);
    try check(.Z012, "pub fn Owned(comptime T: type, comptime cleanup: fn (*T) void) type { return struct { v: T, pub fn deinit(s: *@This()) void { cleanup(&s.v); } }; } fn closeIt(v: *u32) void { v.* = 0; } pub const File = Owned(u32, closeIt); pub fn open() File { return .{ .v = 0 }; }", 0);
    // What a generic's parameter gives is the caller's: a part of it, `@TypeOf` of it.
    try check(.Z012, "pub fn Gen(comptime h: anytype) type { return struct { pub const n = h.n; }; }", 0);
    try check(.Z012, "pub fn get(x: anytype) @TypeOf(x) { return x; }", 0);
    // A public constant holding a type function's call names the type.
    try check(.Z012, "fn StepOf(comptime T: type) type { return struct { t: T }; } pub const Step = StepOf(u8);", 0);
    try check(.Z012, "const Hidden = struct { x: u8 }; fn StepOf(comptime T: type) type { return struct { t: T }; } pub const Step = StepOf(Hidden);", 1);
    // A private alias whose value does not resolve is read as what it is written as.
    try check(.Z012, "fn Backing(comptime T: type) type { return T; } pub fn Atomic(comptime T: type) type { const Repr = Backing(T); return struct { cell: [1]Repr }; }", 1);
    try check(.Z012, "pub fn Backing(comptime T: type) type { return T; } pub fn Atomic(comptime T: type) type { const Repr = Backing(T); return struct { cell: [1]Repr }; }", 0);
}

test "G2 Z012 family API report respects public aliases receivers and suppression" {
    try check(.Z012, "const Hidden = struct {}; pub fn create() Hidden { return .{}; }", 1);
    try check(.Z012, "const Hidden = struct {}; pub fn create() ?*Hidden { return null; }", 1);
    try check(.Z012, "const Hidden = struct {}; pub const Visible = Hidden; pub fn create() Hidden { return .{}; }", 0);
    try check(.Z012, "pub const Visible = struct { pub fn read(self: @This()) void { _ = self; } };", 0);
    // A private container's methods are named by nobody outside the file (reactor's backend sinks).
    try check(.Z012, "const Hidden = struct {}; const Sink = struct { pub fn complete(s: *Sink, h: *Hidden) void { _ = s; _ = h; } };", 0);
    try check(.Z012, "const Hidden = struct {}; pub const Api = struct { const Sink = struct { pub fn take() Hidden { return .{}; } }; };", 0);
    try check(.Z012, "const Hidden = struct {}; pub const Api = struct { pub fn take() Hidden { return .{}; } };", 1);
    try check(.Z012, "const Hidden = struct {};\n// glint-ignore: Z012 -- inference-only factory intentionally hides representation\npub fn create() Hidden { return .{}; }", 0);
}

test "Z012 reads the type a signature names by what it is, each type a caller has to name" {
    // An array's element, through an alias or written in place.
    try check(.Z012, "const Hidden = struct {}; pub fn all() [4]Hidden { return undefined; }", 1);
    try check(.Z012, "pub const Hidden = struct {}; pub fn all() [4]Hidden { return undefined; }", 0);
    try check(.Z012, "const Hidden = struct {}; const Four = [4]Hidden; pub fn all() Four { return undefined; }", 1);
    try check(.Z012, "const Four = [4]u8; pub fn all() Four { return undefined; }", 0);
    // A function type's parameters and result.
    try check(.Z012, "const Hidden = struct {}; pub fn on(callback: *const fn (Hidden) void) void { _ = callback; }", 1);
    try check(.Z012, "pub fn on(callback: *const fn (u8) void) void { _ = callback; }", 0);
    // A container written in the signature: its fields' types.
    try check(.Z012, "const Hidden = struct {}; pub fn pair() struct { h: Hidden } { return undefined; }", 1);
    try check(.Z012, "pub fn pair() struct { h: u8 } { return undefined; }", 0);
    // A public declaration inside a private container is named by nobody outside.
    try check(.Z012, "const Sink = struct { pub const Item = struct {}; }; pub fn get() Sink.Item { return .{}; }", 1);
    try check(.Z012, "pub const Sink = struct { pub const Item = struct {}; }; pub fn get() Sink.Item { return .{}; }", 0);
    // A builtin's type, as Zig computes it.
    try check(.Z012, "const Hidden = struct {}; const h: Hidden = .{}; pub fn get() @TypeOf(h) { return h; }", 1);
    try check(.Z012, "pub const Hidden = struct {}; const h: Hidden = .{}; pub fn get() @TypeOf(h) { return h; }", 0);
    // A made container is named by its type function's call.
    try check(.Z012, "fn Box(comptime T: type) type { return struct { t: T }; } pub fn get() Box(u8) { return undefined; }", 1);
    try check(.Z012, "const Hidden = struct {}; pub fn Box(comptime T: type) type { return struct { t: T }; } pub fn get() Box(Hidden) { return undefined; }", 1);
    try check(.Z012, "pub const Hidden = struct {}; pub fn Box(comptime T: type) type { return struct { t: T }; } pub fn get() Box(Hidden) { return undefined; }", 0);
    // A generic's own container is named through the call that names its function.
    try check(.Z012, "pub fn List(comptime T: type) type { return struct { const Self = @This(); items: []T, pub fn init() Self { return .{ .items = &.{} }; } }; }", 0);
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

test "G2 function length follows configured code policy" {
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

test "a disallowed declaration is the program's module's, never a build script's of the same name and path" {
    const P = glint.Project;
    // Twins: the build runner's scripts, whose `lib` is the dependency's build script, and the
    // same files stated as the program's, where both `lib`s are the module and both calls reach it.
    for ([_]struct { P.Compilations, usize }{ .{ .build, 1 }, .{ .program, 2 } }) |case| {
        const inputs = [_]P.Input{
            .{ .name = "program.zig", .bytes = "const lib = @import(\"lib\");\npub fn main() void { lib.sync(); }\n" },
            .{ .name = "lib/root.zig", .bytes = "pub fn sync() void {}\n", .selected = false },
            .{ .name = "build.zig", .bytes = "const lib = @import(\"lib\");\npub fn build() void { lib.sync(); }\n", .compilations = case[0] },
            .{ .name = "lib/build.zig", .bytes = "pub fn sync() void {}\n", .selected = false, .compilations = case[0] },
        };
        const imports = [_]P.Import{ .{ .from = 0, .spelling = "lib", .target = 1 }, .{ .from = 2, .spelling = "lib", .target = 3 } };
        var project = try P.init(std.testing.allocator, &inputs, &imports, .{});
        defer project.deinit();
        var config = glint.Config.none();
        config.selections = &.{.{ .rule = .P006, .level = .gate }};
        config.disallowed = &.{.{ .source = "lib", .declaration = "sync", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile" }};
        var report = try glint.run(std.testing.allocator, &project, config);
        defer report.deinit();
        try std.testing.expect(report.complete);
        try std.testing.expectEqual(case[1], report.diagnostics.len);
    }
}

test "a file both compilations compile reads a name each binds apart as both: a finding stands where either side's member flags" {
    const P = glint.Project;
    // The program's `lib` and the build's each declare `sync`; only the program's is disallowed.
    // Twins: both declare it (the program's flags, the build's clears: the finding stands); only
    // the program's does (the build's side lacks it and never runs the call); a member both
    // declare and neither flags (clear).
    for ([_]struct { []const u8, []const u8, usize }{
        .{ "pub fn sync() void {}\npub fn flush() void {}\n", "lib.sync();", 1 },
        .{ "pub fn flush() void {}\n", "lib.sync();", 1 },
        .{ "pub fn sync() void {}\npub fn flush() void {}\n", "lib.flush();", 0 },
    }) |case| {
        const shared = try std.mem.concat(std.testing.allocator, u8, &.{ "const lib = @import(\"lib\");\npub fn run() void { ", case[1], " }\n" });
        defer std.testing.allocator.free(shared);
        const inputs = [_]P.Input{
            .{ .name = "program.zig", .bytes = "const shared = @import(\"shared.zig\");\npub fn main() void { shared.run(); }\n" },
            .{ .name = "shared.zig", .bytes = shared, .compilations = .both },
            .{ .name = "lib/root.zig", .bytes = "pub fn sync() void {}\npub fn flush() void {}\n", .selected = false },
            .{ .name = "build.zig", .bytes = "const shared = @import(\"src/shared.zig\");\npub fn build() void { shared.run(); }\n", .compilations = .build },
            .{ .name = "lib/build.zig", .bytes = case[0], .selected = false, .compilations = .build },
        };
        const imports = [_]P.Import{
            .{ .from = 0, .spelling = "shared.zig", .target = 1 },
            .{ .from = 3, .spelling = "src/shared.zig", .target = 1 },
            .{ .from = 1, .spelling = "lib", .target = 2, .compilation = .program },
            .{ .from = 1, .spelling = "lib", .target = 4, .compilation = .build },
        };
        var project = try P.init(std.testing.allocator, &inputs, &imports, .{});
        defer project.deinit();
        var config = glint.Config.none();
        config.selections = &.{.{ .rule = .P006, .level = .gate }};
        config.disallowed = &.{.{ .source = "lib", .declaration = "sync", .reason = "durability belongs to airlock", .replacement = "airlock.syncFile" }};
        var report = try glint.run(std.testing.allocator, &project, config);
        defer report.deinit();
        try std.testing.expect(report.complete);
        try std.testing.expectEqual(case[2], report.diagnostics.len);
    }
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
        .{ .from = 0, .spelling = "lib", .target = 1 },
        .{ .from = 1, .spelling = "posix.zig", .target = 2 },
        .{ .from = 1, .spelling = "c.zig", .target = 3 },
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

/// A run of P006 over a program (`app`), the package that declares the replacements (`airlock`)
/// and one that does not import it (`lone`), every file selected; std a fixture of its own.
fn replacedRun(airlock: []const u8) !glint.Report {
    return replacedRunOn(airlock, glint.Config.none().fact_budget);
}

/// `replacedRun` on a budget of `budget` resolutions.
fn replacedRunOn(airlock: []const u8, budget: usize) !glint.Report {
    const P = glint.Project;
    const inputs = [_]P.Input{
        .{ .name = "app/main.zig", .package = "app", .fingerprint = 1, .bytes =
        \\const std = @import("std");
        \\const airlock = @import("airlock");
        \\extern "c" fn fsync(fd: c_int) c_int;
        \\pub fn main() void {
        \\    std.posix.fdatasync(1);
        \\    _ = fsync(1);
        \\    airlock.syncFile(1);
        \\    std.posix.read(1);
        \\}
        },
        .{ .name = "airlock/root.zig", .package = "airlock", .fingerprint = 2, .bytes = airlock },
        .{ .name = "lone/root.zig", .package = "lone", .fingerprint = 3, .bytes = "const std = @import(\"std\");\npub fn f() void {\n    std.posix.fdatasync(1);\n}\n" },
        .{ .name = "std/std.zig", .selected = false, .bytes = "pub const posix = @import(\"posix.zig\");\n" },
        .{ .name = "std/posix.zig", .selected = false, .bytes = "pub fn fdatasync(fd: i32) void {\n    _ = fd;\n}\npub fn read(fd: i32) void {\n    _ = fd;\n}\n" },
    };
    const imports = [_]P.Import{
        .{ .from = 0, .spelling = "std", .target = 3 },
        .{ .from = 0, .spelling = "airlock", .target = 1 },
        .{ .from = 1, .spelling = "std", .target = 3 },
        .{ .from = 2, .spelling = "std", .target = 3 },
        .{ .from = 3, .spelling = "posix.zig", .target = 4 },
    };
    var project = try P.init(std.testing.allocator, &inputs, &imports, .{});
    defer project.deinit();
    var config = glint.Config.none();
    config.selections = &.{.{ .rule = .P006, .level = .gate }};
    config.fact_budget = budget;
    return glint.run(std.testing.allocator, &project, config);
}

test "P006 reads what a package declares it replaces: in every package that imports it, its own included, save the replacement and what only the replacement reaches" {
    var report = try replacedRun(
        \\const std = @import("std");
        \\pub fn syncFile(fd: i32) void {
        \\    std.posix.fdatasync(fd);
        \\    flush(fd);
        \\    helper(fd);
        \\}
        \\fn flush(fd: i32) void {
        \\    deeper(fd);
        \\}
        \\fn deeper(fd: i32) void {
        \\    std.posix.fdatasync(fd);
        \\}
        \\pub fn other(fd: i32) void {
        \\    std.posix.fdatasync(fd);
        \\}
        \\fn helper(fd: i32) void {
        \\    std.posix.fdatasync(fd);
        \\}
        \\pub const hook: *const fn (i32) void = &helper;
        \\pub const lint_rules = .{
        \\    .version = 1,
        \\    .replaces = .{
        \\        .{ .std = std.posix.fdatasync, .with = syncFile, .why = "durability belongs to airlock" },
        \\        .{ .symbol = "fsync", .with = syncFile, .why = "durability belongs to airlock" },
        \\    },
        \\};
    );
    defer report.deinit();
    try std.testing.expect(report.complete);
    // The program's fdatasync and its own fsync; airlock's `other` and its handed-out `helper`.
    // syncFile, and flush and deeper, which only it reaches, are the replacement's own; `lone`
    // does not import airlock; `read` is not replaced.
    // By file (0 the program, 1 airlock) and line.
    var lines: [8]u32 = undefined;
    var n: usize = 0;
    for (report.diagnostics) |d| {
        try std.testing.expectEqual(glint.Rule.P006, d.rule);
        try std.testing.expect(std.mem.find(u8, d.message, "replaced by airlock: durability belongs to airlock; use syncFile") != null);
        lines[n] = @backingInt(d.span.file) * 100 + d.span.line;
        n += 1;
    }
    std.mem.sort(u32, lines[0..n], {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 5, 6, 114, 117 }, lines[0..n]);
}

/// airlock's replacement reached through a chain of `steps` private functions, each called once by
/// the next: every one of them only the replacement reaches.
fn chained(steps: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator, "const std = @import(\"std\");\npub fn syncFile(fd: i32) void {\n    step0(fd);\n}\n");
    for (0..steps) |i| try text.print(std.testing.allocator, "fn step{d}(fd: i32) void {{\n    step{d}(fd);\n}}\n", .{ i, i + 1 });
    try text.print(std.testing.allocator, "fn step{d}(fd: i32) void {{\n    std.posix.fdatasync(fd);\n}}\npub const lint_rules = .{{ .version = 1, .replaces = .{{.{{ .std = std.posix.fdatasync, .with = syncFile, .why = \"durability belongs to airlock\" }}}} }};\n", .{steps});
    return text.toOwnedSlice(std.testing.allocator);
}

test "P006 follows a function's callers to their end: a chain only the replacement reaches is its own, and one the budget does not read to its end is undecided" {
    const long = try chained(10);
    defer std.testing.allocator.free(long);
    // Read to its end: the chain is the replacement's; only the program's two sites are judged.
    var whole = try replacedRun(long);
    defer whole.deinit();
    try std.testing.expect(whole.complete);
    for (whole.diagnostics) |d| try std.testing.expectEqual(@as(u32, 0), @backingInt(d.span.file));
    try std.testing.expectEqual(@as(usize, 2), whole.diagnostics.len);
    // Past the budget: the site in the chain is undecided, for want of budget, never exempt.
    const longer = try chained(200);
    defer std.testing.allocator.free(longer);
    var short = try replacedRunOn(longer, 150);
    defer short.deinit();
    try std.testing.expect(!short.complete);
    var noted = false;
    for (short.coverage) |note| if (note.rule != null and note.rule.? == .P006 and std.mem.find(u8, note.detail, "may be reached only from the replacement") != null) {
        noted = true;
    };
    try std.testing.expect(noted);
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

test "private import references through reflection strings preserve declaration identity" {
    try check(.Z013, "const Self = @This(); const dep = @import(\"dep\"); pub fn run() void { _ = @field(Self, \"dep\"); }", 0);
    // `@hasDecl` sees no private declaration, even of its own file: the import is unused.
    try check(.Z013, "const Self = @This(); const dep = @import(\"dep\"); pub fn run() void { _ = @hasDecl(Self, \"dep\"); }", 1);
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
        \\pub fn a(x: u8) u8 { assert(x < 9); contract.invariant(x > 0, "positive"); return x; }
        \\pub fn b(x: u8) u8 { std.debug.assert(x != 3); return if (x == 1) contract.never("one") else x; }
        \\pub fn c(x: u8) void { assertLocal(x == 0); }
        \\pub fn d(m: anytype) void { m.invariant(true, "unknown"); }
        \\test { assert(true); }
    ;
    const inputs = [_]P.Input{
        .{ .name = "program.zig", .bytes = program },
        .{ .name = "std.zig", .bytes = "pub const debug = @import(\"debug.zig\");", .selected = false },
        .{ .name = "debug.zig", .bytes = "pub fn assert(ok: bool) void { if (!ok) unreachable; }", .selected = false },
        .{ .name = "aegis.zig", .bytes = "pub const assert = @import(\"assert.zig\");\npub const lint_rules = .{ .version = 1, .roles = .{ .{ .type = assert.invariant, .role = .invariant }, .{ .type = assert.never, .role = .never } } };", .selected = false, .package = glint.AegisPack.package.name, .fingerprint = glint.AegisPack.package.fingerprint },
        .{ .name = "assert.zig", .bytes = "pub fn invariant(ok: bool, comptime m: []const u8) void { if (!ok) @panic(m); }\npub inline fn never(comptime m: []const u8) noreturn { @panic(m); }", .selected = false, .package = glint.AegisPack.package.name, .fingerprint = glint.AegisPack.package.fingerprint },
    };
    const imports = [_]P.Import{
        .{ .from = 0, .spelling = "std", .target = 1 },
        .{ .from = 1, .spelling = "debug.zig", .target = 2 },
        .{ .from = 0, .spelling = "aegis", .target = 3 },
        .{ .from = 3, .spelling = "assert.zig", .target = 4 },
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
    try std.testing.expectEqual(@as(u32, 1), t.assertions[@backingInt(glint.Report.Metrics.Kind.invariant)]); // safe: a kind indexes its own count table.
    try std.testing.expectEqual(@as(u32, 1), t.assertions[@backingInt(glint.Report.Metrics.Kind.never)]); // safe: a kind indexes its own count table.
    try std.testing.expectEqual(@as(u32, 1), t.unresolved); // safe: expected count fits u32.
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try report.write(&text.writer, &project, .text);
    try std.testing.expect(std.mem.find(u8, text.written(), "metrics: 1 files, 5 functions, 2 with an assertion, 5 assertions (std.debug.assert 3, aegis.assert.invariant 1, aegis.assert.never 1), 1 assertion-like calls unresolved\n") != null);
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

test "review Z006 accepts a name a generic reads on its type parameter that an outside type declares" {
    const outside = "pub const Edwards = struct { pub const basePoint: Edwards = .{}; };";
    const own = "const dep = @import(\"dep\");\npub const Point = struct { pub const basePoint: Point = .{}; pub const otherName: Point = .{}; };\nfn table(comptime P: type) P { return P.basePoint; }\npub fn f() void { _ = table(Point); _ = table(dep.Edwards); }";
    for ([_]bool{ true, false }) |generic| {
        const source = if (generic) own else "const dep = @import(\"dep\");\npub const Point = struct { pub const basePoint: Point = .{}; pub const otherName: Point = .{}; };\npub fn f() void { _ = dep; }";
        var project = try glint.Project.init(std.testing.allocator, &.{ .{ .name = "fixture", .stem = "Fixture", .bytes = source }, .{ .name = "dep", .stem = "Dep", .bytes = outside, .selected = false } }, &.{.{ .from = 0, .spelling = "dep", .target = 1 }}, .{});
        defer project.deinit();
        var config = glint.Config.none();
        config.set(.Z006, true);
        var report = try glint.run(std.testing.allocator, &project, config);
        defer report.deinit();
        // `otherName` no outside type declares; `basePoint` only where a generic reads it.
        try std.testing.expectEqual(@as(usize, if (generic) 1 else 2), report.diagnostics.len); // safe: fixture counts are representable.
    }
}

/// An `Io` on which every task has been asked to stop.
const Canceled = @import("shakedown").Layer(u8, .{
    .checkCancel = struct {
        fn checkCancel(_: ?*anyopaque) std.Io.Cancelable!void {
            return error.Canceled;
        }
    }.checkCancel,
});

test "a canceled analysis ends at the next file, building the project or running its rules; with no io it runs on" {
    const sources = [_]glint.Project.Input{ .{ .name = "a.zig", .bytes = "const a = 1;" }, .{ .name = "b.zig", .bytes = "const b = 2;" } };
    var canceled: Canceled = .init(std.testing.io, 0);
    try std.testing.expectError(error.Canceled, glint.Project.init(std.testing.allocator, &sources, &.{}, .{ .io = canceled.io() }));
    var project = try glint.Project.init(std.testing.allocator, &sources, &.{}, .{});
    defer project.deinit();
    const config: glint.Config = .{};
    try std.testing.expectError(error.Canceled, glint.runConfigured(std.testing.allocator, &project, config, .{ .io = canceled.io() }));
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .io = std.testing.io });
    defer report.deinit();
}

/// A rule that fills 64 MiB of its own memory in each file it reads and drops it there.
const touching: glint.Rule = @fromBackingInt(1001); // safe: this test owns its validated extension identity.
fn touch(context: *glint.RuleContext) glint.RuleContext.Error!void {
    const own = try context.allocator.alloc(u8, 64 << 20);
    @memset(own, 0xaa);
}

/// This process's peak resident memory in bytes, null where its system does not say.
fn peakResident() ?usize {
    const builtin = @import("builtin");
    const usage = switch (builtin.os.tag) {
        .linux, .dragonfly, .freebsd, .netbsd, .openbsd, .illumos, .serenity, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => std.posix.getrusage(std.posix.rusage.SELF),
        else => return null,
    };
    const peak: usize = @intCast(usage.maxrss);
    // Darwin's is in bytes, the others' in KiB.
    return if (builtin.os.tag.isDarwin()) peak else peak * 1024;
}

test "a rule's memory for one file is given back when the rule is done with the file" {
    // 64 files: 4 GiB a run kept to its end, as every rule's memory once was (11-03). Given
    // back after each file, the run holds one file's 64 MiB at a time.
    const before = peakResident() orelse return error.SkipZigTest;
    var inputs: [64]glint.Project.Input = undefined;
    var names: [64][8]u8 = undefined;
    for (&inputs, &names, 0..) |*input, *name, i| input.* = .{ .name = try std.mem.print(name, "f{d}", .{i}), .bytes = "pub const x = 1;\n" };
    var project = try glint.Project.init(std.testing.allocator, &inputs, &.{}, .{});
    defer project.deinit();
    const rule: glint.ProjectRule = .{ .definition = .{ .id = touching, .name = "TOUCHES_MEMORY", .group = .family_policy, .purpose = "fills memory of its own in each file", .version = 1 }, .check = touch };
    const config: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = touching, .level = .report }} };
    var report = try glint.runConfigured(std.testing.allocator, &project, config, .{ .project_rules = &.{rule} });
    defer report.deinit();
    const grown = (peakResident() orelse return error.SkipZigTest) -| before;
    try std.testing.expect(grown < 1 << 30);
}
