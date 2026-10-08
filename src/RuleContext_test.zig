const std = @import("std");
const glint = @import("glint");
const own: glint.Rule = @fromBackingInt(1000); // safe: this project owns its validated extension identity.
const rule: glint.ProjectRule = .{ .definition = .{ .id = own, .name = "CUSTOM_API", .group = .family_policy, .purpose = "project requires a declared contract", .version = 7 }, .check = check };
fn check(context: *glint.RuleContext) glint.RuleContext.Error!void {
    const h = try context.source();
    for (try context.project.declarations(h)) |decl| if (decl.public) try context.at(own, decl.token, "public declaration needs the project contract");
}
fn uncertain(context: *glint.RuleContext) glint.RuleContext.Error!void {
    try check(context);
    try context.undecided(own, 0, .unresolved, "generic target lacks a concrete operation contract");
}
fn configuration(level: glint.Config.Level) glint.Config {
    return .{ .enabled = @splat(false), .selections = switch (level) {
        .off => &.{.{ .rule = own, .level = .off }},
        .report => &.{.{ .rule = own, .level = .report }},
        .gate => &.{.{ .rule = own, .level = .gate }},
    } };
}
test "G2 compiled project rules share metadata rendering and written site suppression" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = "pub const bad = 1;\n// glint-ignore: CUSTOM_API -- boundary exports this intentional constant\npub const allowed = 2;" }}, &.{}, .{});
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{ .project_rules = &.{rule} });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: expected single fixture diagnostic.
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: expected single reasoned exception.
    try std.testing.expectEqualStrings("CUSTOM_API", report.diagnostics[0].name);
    try std.testing.expectEqual(@as(u32, 7), report.diagnostics[0].rule_version); // safe: known metadata version.
    for ([_]glint.Report.Format{ .text, .json, .sarif }) |format| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try report.write(&output.writer, &project, format);
        try std.testing.expect(std.mem.find(u8, output.written(), "CUSTOM_API") != null);
    }
}
test "G2 incomplete required project rule stays incomplete with every finding allowed" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = "// glint-ignore: CUSTOM_API -- intentionally exported test contract\npub const allowed = 2;" }}, &.{}, .{});
    defer project.deinit();
    var modified = rule;
    modified.check = uncertain;
    var report = try glint.runConfigured(std.testing.allocator, &project, configuration(.gate), .{ .project_rules = &.{modified} });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 0), report.diagnostics.len); // safe: no unsuppressed findings.
    try std.testing.expectEqual(@as(usize, 1), report.suppressed); // safe: expected site exception.
    try std.testing.expect(!report.complete);
    for ([_]glint.Report.Format{ .json, .sarif }) |format| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try report.write(&output.writer, &project, format);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
        defer parsed.deinit();
        try std.testing.expect(std.mem.find(u8, output.written(), "CUSTOM_API") != null);
    }
    try std.testing.expectEqualStrings("CUSTOM_API", report.coverage[report.coverage.len - 1].rule_name);
}
test "G2 compiled rules reject missing definitions collisions and invalid spans" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = "pub const x = 1;" }}, &.{}, .{});
    defer project.deinit();
    try std.testing.expectError(error.InvalidSelection, glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{}));
    try std.testing.expectError(error.InvalidSelection, glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{ .project_rules = &.{ rule, rule } }));
    const Invalid = struct {
        fn run(context: *glint.RuleContext) glint.RuleContext.Error!void {
            try context.emit(own, 0, 100, "outside source");
        }
    };
    var bad = rule;
    bad.check = Invalid.run;
    try std.testing.expectError(error.InvalidHandle, glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{ .project_rules = &.{bad} }));
    const InvalidNode = struct {
        fn run(context: *glint.RuleContext) glint.RuleContext.Error!void {
            try context.unknown(own, @fromBackingInt(1000), .unresolved); // safe: deliberately invalid frozen node for boundary rejection.
        }
    };
    bad.check = InvalidNode.run;
    try std.testing.expectError(error.InvalidHandle, glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{ .project_rules = &.{bad} }));
}
test "G2 caller selects per-file rule levels without importing a path dialect" {
    var project = try glint.Project.init(std.testing.allocator, &.{ .{ .name = "chosen", .bytes = "pub const x = 1;" }, .{ .name = "excluded", .bytes = "pub const y = 2;" } }, &.{}, .{});
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, configuration(.off), .{ .project_rules = &.{rule}, .files = &.{.{ .file = glint.Project.FileId.fromRaw(0), .config = configuration(.report) }} });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: only selected source reports.
    try std.testing.expect(report.diagnostics[0].span.file.eql(glint.Project.FileId.fromRaw(0)));
}
