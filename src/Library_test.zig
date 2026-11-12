//! A pack finds a library's declarations by the roles the library's package declares for them.
const std = @import("std");
const glint = @import("glint");
const shakedown = @import("shakedown");
const P = glint.Project;
const Role = enum(u8) { widget, gauge, legacy };
const gadgets: @FieldType(glint.Library(Role), "package") = .{ .name = "gadgets", .fingerprint = 0x9ad9e75 };
const library: glint.Library(Role) = .{ .package = gadgets };
const own: glint.Rule = @fromBackingInt(1000); // safe: this project owns its validated extension identity.
const rule: glint.ProjectRule = .{ .definition = .{ .id = own, .name = "ROLE_PROBE", .group = .family_policy, .purpose = "reports the role a library gives each public constant", .version = 1 }, .check = probe, .roles = &.{ "widget", "gauge", "legacy" } };

/// Reports, for each public constant, the role of what it names, or that it names none.
fn probe(context: *glint.RuleContext) glint.RuleContext.Error!void {
    const tree = try context.project.syntax(try context.source());
    if (try context.inLibrary(library, context.file)) return;
    if (try context.drift(library)) |gap| try context.undecided(own, gap.start, .unresolved, gap.detail);
    for (try context.project.declarations(try context.source())) |decl| {
        if (!decl.public) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        const found = try context.role(library, try context.facts.resolve(context.file, init));
        try context.at(own, decl.token, if (found) |role| @tagName(role) else "none");
    }
}
const config: glint.Config = .{ .enabled = .empty, .selections = &.{.{ .rule = own, .level = .gate }} };

const Layout = struct { name: []const u8, bytes: []const u8 };
/// The consumer, then `layout`'s files, each of the gadgets package; entry 0 is its root.
fn project(a: std.mem.Allocator, bytes: []const u8, layout: []const Layout) !P {
    var inputs: [8]P.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = bytes };
    for (layout, 1..) |entry, i| inputs[i] = .{ .name = entry.name, .bytes = entry.bytes, .selected = false, .package = gadgets.name, .fingerprint = gadgets.fingerprint };
    // Files reach each other by their relative names.
    var imports: [16]P.Import = undefined;
    imports[0] = .{ .from = 0, .spelling = "gadgets", .target = 1 };
    var count: usize = 1;
    for (layout, 1..) |_, from| for (layout[1..], 2..) |target, to| {
        if (from == to) continue;
        imports[count] = .{ .from = from, .spelling = target.name, .target = to }; // safe: the fixture has a handful of files.
        count += 1;
    };
    return P.init(a, inputs[0 .. layout.len + 1], imports[0..count], .{});
}
fn probeAll(bytes: []const u8, layout: []const Layout) !struct { project: P, report: glint.Report } {
    var built = try project(std.testing.allocator, bytes, layout);
    errdefer built.deinit();
    const report = try glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{rule} });
    return .{ .project = built, .report = report };
}
fn expectMessages(report: glint.Report, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, report.diagnostics.len);
    for (expected, report.diagnostics) |message, diagnostic| try std.testing.expectEqualStrings(message, diagnostic.message);
}
fn coverage(report: glint.Report) ?[]const u8 {
    var detail: ?[]const u8 = null;
    for (report.coverage) |entry| if (entry.rule != null) {
        detail = entry.detail;
    };
    return detail;
}
const consumer =
    \\const gadgets = @import("gadgets");
    \\pub const A = gadgets.Widget;
    \\pub const B = gadgets.Widget(u8);
    \\pub const C = gadgets.kit.Gauge;
    \\pub const D = gadgets.kit.Gauge(u16);
    \\pub const E = struct {};
    \\pub const F = gadgets.kit;
;
const rules = "pub const lint_rules = .{ .version = 1, .roles = .{ .{ .type = Widget, .role = .widget }, .{ .type = kit.Gauge, .role = .gauge }, .{ .type = kit.Gauge, .role = .secret } } };\n";
const flat = [_]Layout{
    .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\npub const kit = @import(\"kit.zig\");\n" ++ rules },
    .{ .name = "widget.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }" },
    .{ .name = "kit.zig", .bytes = "pub fn Gauge(comptime T: type) type { return struct { reading: T }; }" },
};
// The same declarations moved, rewritten and checked before they return.
const moved = [_]Layout{
    .{ .name = "gadgets.zig", .bytes = "const inner = @import(\"inner.zig\");\npub const Widget = inner.Widget;\npub const kit = inner.kit;\n" ++ rules },
    .{ .name = "inner.zig", .bytes = "pub const kit = @import(\"kit_impl.zig\");\n/// Reworded.\npub fn Widget(comptime T: type) type {\n    comptime check(T);\n    return struct { payload: T, extra: u8 = 0 };\n}\nfn check(comptime T: type) void { _ = T; }" },
    .{ .name = "kit_impl.zig", .bytes = "pub fn Gauge(comptime T: type) type {\n    if (@sizeOf(T) == 0) @compileError(\"zero\");\n    return struct { level: T };\n}" },
};

test "a declared role is recognized across any layout, by the declaration it names; a role the pack does not name is another pack's" {
    for ([_][]const Layout{ &flat, &moved }) |layout| {
        var run = try probeAll(consumer, layout);
        defer run.project.deinit();
        defer run.report.deinit();
        try std.testing.expect(run.report.complete);
        try expectMessages(run.report, &.{ "widget", "widget", "gauge", "gauge", "none", "none" });
    }
}
test "a replacement or deprecation that does not resolve leaves the declared roles read, with no drift: it is the declarer's to fix where its own lint reports it" {
    const unresolved = [_]Layout{
        .{ .name = "gadgets.zig", .bytes = "const std = @import(\"std\");\npub const Widget = @import(\"widget.zig\").Widget;\npub const kit = @import(\"kit.zig\");\n" ++
            "pub const lint_rules = .{ .version = 1, .replaces = .{.{ .std = std.Io.Dir.gone, .with = Widget, .why = \"r\" }}, .deprecated = .{.{ .decl = kit.gone, .with = null, .why = \"d\" }}, .roles = .{ .{ .type = Widget, .role = .widget }, .{ .type = kit.Gauge, .role = .gauge } } };\n" },
        flat[1],
        flat[2],
    };
    var run = try probeAll(consumer, &unresolved);
    defer run.project.deinit();
    defer run.report.deinit();
    try std.testing.expect(run.report.complete);
    try expectMessages(run.report, &.{ "widget", "widget", "gauge", "gauge", "none", "none" });
}
test "the same declarations under another package are not the library's" {
    var built = try P.init(std.testing.allocator, &.{
        .{ .name = "consumer", .bytes = "const lookalike = @import(\"lookalike\");\npub const A = lookalike.Widget;\npub const B = lookalike.Widget(u8);" },
        .{ .name = "widget.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }", .selected = false },
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\n" ++ "pub const lint_rules = .{ .version = 1, .roles = .{.{ .type = Widget, .role = .widget }} };\n", .selected = false },
    }, &.{
        .{ .from = 0, .spelling = "lookalike", .target = 2 },
        .{ .from = 2, .spelling = "widget.zig", .target = 1 },
    }, .{});
    defer built.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{rule} });
    defer report.deinit();
    try expectMessages(report, &.{ "none", "none" });
}
test "a root of the package that declares no lint_rules is drift where it is imported, and its types read no role" {
    const bare = [_]Layout{
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\n" },
        flat[1],
    };
    var run = try probeAll("const gadgets = @import(\"gadgets\");\npub const A = gadgets.Widget;", &bare);
    defer run.project.deinit();
    defer run.report.deinit();
    try std.testing.expect(!run.report.complete);
    try std.testing.expectEqualStrings("gadgets's root gadgets.zig declares no lint_rules; the roles of its types are not read in this file", coverage(run.report).?);
    try expectMessages(run.report, &.{"none"});
}
test "a reference in lint_rules that does not resolve is drift with where it is written, and the rest is read" {
    const dropped = [_]Layout{
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\npub const kit = @import(\"kit.zig\");\n" ++
            "pub const lint_rules = .{ .version = 1, .roles = .{\n    .{ .type = Widget, .role = .widget },\n    .{ .type = kit.Meter, .role = .gauge },\n} };\n" },
        flat[1],
        flat[2],
    };
    var run = try probeAll(consumer, &dropped);
    defer run.project.deinit();
    defer run.report.deinit();
    try std.testing.expect(!run.report.complete);
    try std.testing.expectEqualStrings("gadgets's lint_rules at gadgets.zig:5: a reference that does not resolve; the roles it declares are not all read in this file", coverage(run.report).?);
    try expectMessages(run.report, &.{ "widget", "widget", "none", "none", "none", "none" });
}
test "a version of lint_rules the reader does not know is drift, and none of its roles are read" {
    const later = [_]Layout{
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\npub const lint_rules = .{ .version = 3, .roles = .{.{ .type = Widget, .role = .widget }} };\n" },
        flat[1],
    };
    var run = try probeAll("const gadgets = @import(\"gadgets\");\npub const A = gadgets.Widget;", &later);
    defer run.project.deinit();
    defer run.report.deinit();
    try std.testing.expect(!run.report.complete);
    try std.testing.expectEqualStrings("gadgets's lint_rules at gadgets.zig:2: a version of the vocabulary this glint does not read; the roles it declares are not all read in this file", coverage(run.report).?);
    try expectMessages(run.report, &.{"none"});
}
test "the library's own files are not checked and two roots of the package are both read" {
    const stated: P.Input = .{ .name = "", .bytes = "", .package = gadgets.name, .fingerprint = gadgets.fingerprint };
    var one = stated;
    one.name = "one.zig";
    one.bytes = "pub const Widget = @import(\"w1.zig\").Widget;\npub const Unused = 1;\npub const lint_rules = .{ .version = 1, .roles = .{.{ .type = Widget, .role = .widget }} };\n";
    var w1 = stated;
    w1.name = "w1.zig";
    w1.bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }\npub const Internal = Widget;";
    var two = stated;
    two.name = "two.zig";
    two.bytes = "pub const Gauge = @import(\"g2.zig\").Gauge;\npub const lint_rules = .{ .version = 1, .roles = .{.{ .type = Gauge, .role = .gauge }} };\n";
    var g2 = stated;
    g2.name = "g2.zig";
    g2.bytes = "pub fn Gauge(comptime T: type) type { return struct { other: T }; }";
    var built = try P.init(std.testing.allocator, &.{
        .{ .name = "first", .bytes = "const g = @import(\"gadgets\");\npub const A = g.Widget;" },
        .{ .name = "second", .bytes = "const g = @import(\"gadgets.two\");\npub const B = g.Gauge;" },
        one,
        w1,
        two,
        g2,
    }, &.{
        .{ .from = 0, .spelling = "gadgets", .target = 2 },
        .{ .from = 1, .spelling = "gadgets.two", .target = 4 },
        .{ .from = 2, .spelling = "w1.zig", .target = 3 },
        .{ .from = 4, .spelling = "g2.zig", .target = 5 },
    }, .{});
    defer built.deinit();
    // Every source is selected, the library's own files too: they are internals, so the probe skips them.
    var report = try glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{rule} });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try expectMessages(report, &.{ "widget", "gauge" });
}
test "library resolution releases allocation failures" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var built = try project(a, consumer, &flat);
            defer built.deinit();
            var report = try glint.runConfigured(a, &built, config, .{ .project_rules = &.{rule} });
            defer report.deinit();
            try std.testing.expectEqual(@as(usize, 6), report.diagnostics.len); // safe: one finding per public constant.
        }
    };
    var allocation: shakedown.alloc.NoResize = .init(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(allocation.allocator(), Case.run, .{});
}
test "a type function with several returns has no single template, yet is still recognized where it is called" {
    const branching = [_]Layout{
        flat[0],
        .{ .name = "widget.zig", .bytes = "pub fn Widget(comptime T: type) type {\n    if (@sizeOf(T) == 0) return struct {};\n    return struct { value: T };\n}" },
        flat[2],
    };
    var run = try probeAll(consumer, &branching);
    defer run.project.deinit();
    defer run.report.deinit();
    try expectMessages(run.report, &.{ "widget", "none", "gauge", "gauge", "none", "none" });
}
test "a role no pack of the run reads is drift where the package is imported, and a finding in the package's own lint" {
    const misspelt = [_]Layout{
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\npub const lint_rules = .{ .version = 1, .roles = .{.{ .type = Widget, .role = .widgte }} };\n" },
        flat[1],
    };
    var run = try probeAll("const gadgets = @import(\"gadgets\");\npub const A = gadgets.Widget;", &misspelt);
    defer run.project.deinit();
    defer run.report.deinit();
    try std.testing.expect(!run.report.complete);
    try std.testing.expectEqualStrings("gadgets's lint_rules at gadgets.zig:2: a role no pack of this run reads; the roles it declares are not all read in this file", coverage(run.report).?);
    // The package's own lint: its root is the program's file, and the run is incomplete where the
    // role is written, whatever rules it selects.
    var own_lint = try P.init(std.testing.allocator, &.{.{ .name = "gadgets.zig", .bytes = misspelt[0].bytes, .package = gadgets.name, .fingerprint = gadgets.fingerprint }}, &.{}, .{});
    defer own_lint.deinit();
    var report = try glint.run(std.testing.allocator, &own_lint, glint.Config.none());
    defer report.deinit();
    try std.testing.expect(!report.complete);
    try std.testing.expectEqual(@as(usize, 1), report.malformed.len);
    try std.testing.expectEqual(@as(u32, 2), report.malformed[0].span.line);
    try std.testing.expectEqualStrings("lint_rules: unknown_role: glint does not read this part, so the programs that import this package do not know what it declares", report.malformed[0].why);
}
test "two packs that give one role name in different lists are refused, so a package's role names one pack" {
    var built = try project(std.testing.allocator, consumer, &flat);
    defer built.deinit();
    var clashing = rule;
    clashing.roles = &.{ "widget", "secret" };
    try std.testing.expectError(error.InvalidSelection, glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{clashing} }));
}
