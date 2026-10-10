//! A pack finds a library's declarations by where the library publishes them.
const std = @import("std");
const glint = @import("glint");
const shakedown = @import("shakedown");
const P = glint.Project;
const Role = enum(u8) { widget, gauge, legacy };
const library: glint.Library(Role) = .{ .modules = &.{
    .{ .name = "gadgets", .members = &.{
        .{ .path = "Widget", .role = .widget },
        .{ .path = "kit.Gauge", .role = .gauge },
        .{ .path = "Legacy", .role = .legacy, .required = false },
    } },
    .{ .name = "gadgets.kit", .members = &.{.{ .path = "Gauge", .role = .gauge }} },
} };
const own: glint.Rule = @fromBackingInt(1000); // safe: this project owns its validated extension identity.
const rule: glint.ProjectRule = .{ .definition = .{ .id = own, .name = "ROLE_PROBE", .group = .family_policy, .purpose = "reports the role a library gives each public constant", .version = 1 }, .check = probe };

/// Reports, for each public constant, the role of what it names, or that it names none.
fn probe(context: *glint.RuleContext) glint.RuleContext.Error!void {
    const tree = try context.project.syntax(try context.source());
    if (try context.inLibrary(library, context.file)) return;
    if (try context.drift(library)) |gap| {
        const detail = try context.allocator.print("drift {s} {s} {t}", .{ gap.module, gap.path, gap.why });
        try context.undecided(own, gap.start, .unresolved, detail);
    }
    for (try context.project.declarations(try context.source())) |decl| {
        if (!decl.public) continue;
        const variable = tree.fullVarDecl(decl.node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        const found = try context.role(library, try context.facts.resolve(context.file, init));
        try context.at(own, decl.token, if (found) |role| @tagName(role) else "none");
    }
}
const config: glint.Config = .{ .enabled = @splat(false), .selections = &.{.{ .rule = own, .level = .gate }} };

const Layout = struct { name: []const u8, bytes: []const u8 };
fn project(bytes: []const u8, layout: []const Layout) !P {
    var inputs: [8]P.Input = undefined;
    inputs[0] = .{ .name = "consumer", .bytes = bytes };
    for (layout, 1..) |entry, i| inputs[i] = .{ .name = entry.name, .bytes = entry.bytes, .selected = false };
    // Layout entry 0 is the module root. Files reach each other by their relative names.
    var imports: [16]P.Import = undefined;
    imports[0] = .{ .from = P.FileId.fromRaw(0), .spelling = "gadgets", .target = P.FileId.fromRaw(1) };
    var count: usize = 1;
    for (layout, 1..) |_, from| for (layout[1..], 2..) |target, to| {
        if (from == to) continue;
        imports[count] = .{ .from = P.FileId.fromRaw(@intCast(from)), .spelling = target.name, .target = P.FileId.fromRaw(@intCast(to)) }; // safe: the fixture has a handful of files.
        count += 1;
    };
    return P.init(std.testing.allocator, inputs[0 .. layout.len + 1], imports[0..count], .{});
}
fn probeAll(bytes: []const u8, layout: []const Layout) !struct { project: P, report: glint.Report } {
    var built = try project(bytes, layout);
    errdefer built.deinit();
    const report = try glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{rule} });
    return .{ .project = built, .report = report };
}
fn expectMessages(report: glint.Report, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, report.diagnostics.len);
    for (expected, report.diagnostics) |message, diagnostic| try std.testing.expectEqualStrings(message, diagnostic.message);
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
const flat = [_]Layout{
    .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\npub const kit = @import(\"kit.zig\");" },
    .{ .name = "widget.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }" },
    .{ .name = "kit.zig", .bytes = "pub fn Gauge(comptime T: type) type { return struct { reading: T }; }" },
};
// The same public names, with the declarations moved, rewritten and checked before they return.
const moved = [_]Layout{
    .{ .name = "gadgets.zig", .bytes = "const inner = @import(\"inner.zig\");\npub const Widget = inner.Widget;\npub const kit = inner.kit;\n" },
    .{ .name = "inner.zig", .bytes = "pub const kit = @import(\"kit_impl.zig\");\n/// Reworded.\npub fn Widget(comptime T: type) type {\n    comptime check(T);\n    return struct { payload: T, extra: u8 = 0 };\n}\nfn check(comptime T: type) void { _ = T; }" },
    .{ .name = "kit_impl.zig", .bytes = "pub fn Gauge(comptime T: type) type {\n    if (@sizeOf(T) == 0) @compileError(\"zero\");\n    return struct { level: T };\n}" },
};

test "a published declaration is recognized across any layout that keeps its public names" {
    for ([_][]const Layout{ &flat, &moved }) |layout| {
        var run = try probeAll(consumer, layout);
        defer run.project.deinit();
        defer run.report.deinit();
        try std.testing.expect(run.report.complete);
        try expectMessages(run.report, &.{ "widget", "widget", "gauge", "gauge", "none", "none" });
    }
}
test "a lookalike declaration under another module is not the library's" {
    var built = try P.init(std.testing.allocator, &.{
        .{ .name = "consumer", .bytes = "const lookalike = @import(\"lookalike\");\npub const A = lookalike.Widget;\npub const B = lookalike.Widget(u8);" },
        .{ .name = "widget.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }", .selected = false },
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;", .selected = false },
    }, &.{
        .{ .from = P.FileId.fromRaw(0), .spelling = "lookalike", .target = P.FileId.fromRaw(2) },
        .{ .from = P.FileId.fromRaw(2), .spelling = "widget.zig", .target = P.FileId.fromRaw(1) },
    }, .{});
    defer built.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{rule} });
    defer report.deinit();
    try expectMessages(report, &.{ "none", "none" });
}
test "a dropped required member is drift, an absent optional member is not" {
    const dropped = [_]Layout{
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\npub const kit = @import(\"kit.zig\");" },
        .{ .name = "widget.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }" },
        .{ .name = "kit.zig", .bytes = "pub fn Dial(comptime T: type) type { return struct { reading: T }; }" },
    };
    var run = try probeAll(consumer, &dropped);
    defer run.project.deinit();
    defer run.report.deinit();
    // Gate level: coverage the pack could not resolve makes the run incomplete, not clean.
    try std.testing.expect(!run.report.complete);
    var drift: usize = 0;
    for (run.report.coverage) |entry| if (entry.rule != null and std.mem.startsWith(u8, entry.detail, "drift gadgets kit.Gauge")) {
        drift += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), drift); // safe: one coverage entry per importing file.
    for (run.report.coverage) |entry| try std.testing.expect(std.mem.find(u8, entry.detail, "Legacy") == null);
    var complete = try probeAll(consumer, &flat);
    defer complete.project.deinit();
    defer complete.report.deinit();
    try std.testing.expect(complete.report.complete);
}
test "an unmapped namespace is drift with its reason" {
    var built = try P.init(std.testing.allocator, &.{
        .{ .name = "consumer", .bytes = "const gadgets = @import(\"gadgets\");\npub const A = gadgets.Widget;" },
        .{ .name = "gadgets.zig", .bytes = "pub const Widget = @import(\"widget.zig\").Widget;\npub const kit = @import(\"kit.zig\");", .selected = false },
        .{ .name = "widget.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }", .selected = false },
    }, &.{
        .{ .from = P.FileId.fromRaw(0), .spelling = "gadgets", .target = P.FileId.fromRaw(1) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "widget.zig", .target = P.FileId.fromRaw(2) },
    }, .{});
    defer built.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{rule} });
    defer report.deinit();
    try std.testing.expect(!report.complete);
    var found = false;
    for (report.coverage) |entry| if (std.mem.eql(u8, entry.detail, "drift gadgets kit.Gauge missing_mapping")) {
        found = true;
    };
    try std.testing.expect(found);
}
test "the library's own files are not checked and two roots are both recognized" {
    var built = try P.init(std.testing.allocator, &.{
        .{ .name = "first", .bytes = "const g = @import(\"gadgets\");\npub const A = g.Widget;" },
        .{ .name = "second", .bytes = "const g = @import(\"gadgets\");\npub const B = g.Widget;" },
        .{ .name = "one.zig", .bytes = "pub const Widget = @import(\"w1.zig\").Widget;\npub const kit = @import(\"k1.zig\");\npub const Unused = 1;" },
        .{ .name = "w1.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { value: T }; }\npub const Internal = Widget;" },
        .{ .name = "k1.zig", .bytes = "pub fn Gauge(comptime T: type) type { return struct { value: T }; }" },
        .{ .name = "two.zig", .bytes = "pub const Widget = @import(\"w2.zig\").Widget;\npub const kit = @import(\"k2.zig\");" },
        .{ .name = "w2.zig", .bytes = "pub fn Widget(comptime T: type) type { return struct { other: T }; }" },
        .{ .name = "k2.zig", .bytes = "pub fn Gauge(comptime T: type) type { return struct { other: T }; }" },
    }, &.{
        .{ .from = P.FileId.fromRaw(0), .spelling = "gadgets", .target = P.FileId.fromRaw(2) },
        .{ .from = P.FileId.fromRaw(1), .spelling = "gadgets", .target = P.FileId.fromRaw(5) },
        .{ .from = P.FileId.fromRaw(2), .spelling = "w1.zig", .target = P.FileId.fromRaw(3) },
        .{ .from = P.FileId.fromRaw(2), .spelling = "k1.zig", .target = P.FileId.fromRaw(4) },
        .{ .from = P.FileId.fromRaw(5), .spelling = "w2.zig", .target = P.FileId.fromRaw(6) },
        .{ .from = P.FileId.fromRaw(5), .spelling = "k2.zig", .target = P.FileId.fromRaw(7) },
    }, .{});
    defer built.deinit();
    // Every source is selected, the library's own files too: they are internals, so the probe skips them.
    var report = try glint.runConfigured(std.testing.allocator, &built, config, .{ .project_rules = &.{rule} });
    defer report.deinit();
    try std.testing.expect(report.complete);
    try expectMessages(report, &.{ "widget", "widget" });
}
test "library resolution releases allocation failures" {
    const Case = struct {
        fn run(a: std.mem.Allocator) !void {
            var built = try P.init(a, &.{
                .{ .name = "consumer", .bytes = consumer },
                .{ .name = flat[0].name, .bytes = flat[0].bytes, .selected = false },
                .{ .name = flat[1].name, .bytes = flat[1].bytes, .selected = false },
                .{ .name = flat[2].name, .bytes = flat[2].bytes, .selected = false },
            }, &.{
                .{ .from = P.FileId.fromRaw(0), .spelling = "gadgets", .target = P.FileId.fromRaw(1) },
                .{ .from = P.FileId.fromRaw(1), .spelling = flat[1].name, .target = P.FileId.fromRaw(2) },
                .{ .from = P.FileId.fromRaw(1), .spelling = flat[2].name, .target = P.FileId.fromRaw(3) },
            }, .{});
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
