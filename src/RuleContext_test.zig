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
    return .{ .enabled = .empty, .selections = switch (level) {
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
        if (format == .sarif) {
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output.written(), .{});
            defer parsed.deinit();
            const properties = parsed.value.object.get("runs").?.array.items[0].object.get("results").?.array.items[0].object.get("properties").?;
            try std.testing.expectEqualStrings("report", properties.object.get("policyLevel").?.string);
            try std.testing.expectEqual(@as(i64, 7), properties.object.get("ruleVersion").?.integer); // safe: exact custom metadata version.
        }
    }
    var gated = try glint.runConfigured(std.testing.allocator, &project, configuration(.gate), .{ .project_rules = &.{rule} });
    defer gated.deinit();
    try std.testing.expect(gated.complete);
    try std.testing.expectEqual(@as(usize, 1), gated.gateFindings()); // safe: one gate finding, separate from one reasoned site.
    try std.testing.expectEqual(@as(usize, 0), report.gateFindings()); // safe: reports do not gate.
}
/// Reaches each public declaration three times with one cause, its related place a different
/// token each time but the last, and once with another cause.
fn repeating(context: *glint.RuleContext) glint.RuleContext.Error!void {
    const h = try context.source();
    for (try context.project.declarations(h)) |decl| if (decl.public) {
        const tree = try context.project.syntax(h);
        const site = tree.tokenToSpan(decl.token);
        for ([_]u32{ 0, 1, 1 }) |step| {
            const related = [_]glint.Report.Span{context.spanOf(context.file, decl.token + step)};
            try context.emitRelated(own, site.start, site.end, "public declaration needs the project contract", &related);
        }
        try context.at(own, decl.token, "public declaration needs a second contract");
    };
}
test "G2 a finding is one per rule, site and cause, however many times its rule reaches it, with the related places of each" {
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = "pub const bad = 1;\n// glint-ignore: CUSTOM_API -- boundary exports this intentional constant\npub const allowed = 2;" }}, &.{}, .{});
    defer project.deinit();
    var report = try glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{ .project_rules = &.{.{ .definition = rule.definition, .check = repeating }} });
    defer report.deinit();
    // Each cause at `bad` once; the escaped site's two causes each taken once.
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: two causes at one site.
    try std.testing.expectEqual(@as(usize, 2), report.suppressed); // safe: two causes at the escaped site.
    for (report.diagnostics) |diagnostic| try std.testing.expectEqual(report.diagnostics[0].span, diagnostic.span);
    const repeated = for (report.diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.message, "public declaration needs the project contract")) break diagnostic;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), repeated.related.len); // safe: two distinct related places of three.
    try std.testing.expect(repeated.related[0].start != repeated.related[1].start);
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
test "a project linter skips an escape for a rule glint has that its run does not enable, counted in one coverage line; a rule glint does not have is malformed, and an enabled rule's unused suppression is stale" {
    // The pack is not this run's, and Z013 is off: neither escape is judged.
    var inactive = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = "pub fn f(buffer: []u8) void {\n    // aegis: design(A019): read only below what it wrote\n    _ = buffer;\n    // glint-ignore: Z013 -- the deprecated name is kept for one release\n    _ = buffer;\n}\n" }}, &.{}, .{});
    defer inactive.deinit();
    var skipped = try glint.runConfigured(std.testing.allocator, &inactive, configuration(.report), .{ .project_rules = &.{rule} });
    defer skipped.deinit();
    try std.testing.expectEqual(@as(usize, 0), skipped.malformed.len); // safe: no malformed comment.
    try std.testing.expectEqual(@as(usize, 0), skipped.stale_suppressions); // safe: a rule that does not run judges nothing.
    try std.testing.expectEqual(@as(usize, 0), skipped.escapes.len); // safe: an unjudged escape covers nothing.
    var lines: usize = 0;
    for (skipped.coverage) |item| if (std.mem.eql(u8, item.detail, "2 escapes for rules this run does not enable")) {
        lines += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), lines); // safe: one line for the file's two.
    // A rule no core, pack or project has: malformed, as before.
    var unknown = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = "pub fn f(buffer: []u8) void {\n    // aegis: design(A999): read only below what it wrote\n    _ = buffer;\n}\n" }}, &.{}, .{});
    defer unknown.deinit();
    var refused = try glint.runConfigured(std.testing.allocator, &unknown, configuration(.report), .{ .project_rules = &.{rule} });
    defer refused.deinit();
    try std.testing.expectEqual(@as(usize, 1), refused.malformed.len); // safe: the one unknown name.
    try std.testing.expectEqualStrings("an aegis escape names a rule glint does not have", refused.malformed[0].why);
    try std.testing.expect(!refused.complete);
    // The project's own rule runs: its suppression that suppresses nothing is stale.
    var enabled = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = "// glint-ignore: CUSTOM_API -- the boundary exports this constant\nconst kept = 2;\npub fn f() u32 {\n    return kept;\n}\n" }}, &.{}, .{});
    defer enabled.deinit();
    var stale = try glint.runConfigured(std.testing.allocator, &enabled, configuration(.report), .{ .project_rules = &.{rule} });
    defer stale.deinit();
    try std.testing.expectEqual(@as(usize, 1), stale.stale_suppressions); // safe: the one unused suppression.
    try std.testing.expectEqualStrings("CUSTOM_API", stale.stale[0].name);
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
    var report = try glint.runConfigured(std.testing.allocator, &project, configuration(.off), .{ .project_rules = &.{rule}, .files = &.{.{ .file = project.sources[0].id, .config = configuration(.report) }} });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 1), report.diagnostics.len); // safe: only selected source reports.
    try std.testing.expect(report.diagnostics[0].span.file == project.sources[0].id);
}

/// Reports each call `x.read(...)` that `Lib.read` cannot be, by `RuleContext.accepts`.
fn refusedCalls(context: *glint.RuleContext) glint.RuleContext.Error!void {
    const h = try context.source();
    const tree = try context.project.syntax(h);
    const declarations = try context.project.declarations(h);
    const read: glint.Symbol = for (declarations, 0..) |decl, i| {
        if (decl.kind == .function and std.mem.eql(u8, decl.name, "read")) break .{ .file = context.file, .index = @fromBackingInt(@intCast(i)) }; // safe: declaration indexes are bounded by the frozen model.
    } else return;
    for (0..tree.nodes.len) |i| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(i)); // safe: AST node table supplies bounded indexes.
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = tree.fullCall(&buffer, node) orelse continue;
        if (tree.nodeTag(call.ast.fn_expr) != .field_access) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeData(call.ast.fn_expr).node_and_token[1]), "read")) continue;
        if (!try context.accepts(read, call, 1)) try context.at(own, tree.nodeMainToken(node), "no `read` of Lib's");
    }
}

test "a call given a type made by a type function or a type builtin is no function's that takes a value" {
    const source =
        \\const Io = struct {};
        \\const Lib = struct {
        \\    fn read(self: *Lib, io: Io) void {
        \\        _ = .{ self, io };
        \\    }
        \\};
        \\fn Pairs(comptime T: type) type {
        \\    return struct { items: []const T };
        \\}
        \\pub fn f(x: anytype) void {
        \\    _ = x.read(Pairs(u8));
        \\    _ = x.read(@TypeOf(x));
        \\    _ = x.read(Io{});
        \\}
    ;
    var project = try glint.Project.init(std.testing.allocator, &.{.{ .name = "project", .bytes = source }}, &.{}, .{});
    defer project.deinit();
    const checking: glint.ProjectRule = .{ .definition = rule.definition, .check = refusedCalls };
    var report = try glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{ .project_rules = &.{checking} });
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: the two type arguments are refused, the value accepted.
}

/// Reports each function declaration that is not test code, by `RuleContext.inTest`.
fn productionFunctions(context: *glint.RuleContext) glint.RuleContext.Error!void {
    for (try context.project.declarations(try context.source())) |decl| {
        if (decl.kind == .function and !context.inTest(decl.token)) try context.at(own, decl.token, "production function");
    }
}

test "test code is a test block or an input classified test, never what only tests reach" {
    const root =
        \\fn helper() u32 {
        \\    return 1;
        \\}
        \\test "uses the helper and the support file" {
        \\    const support = @import("support.zig");
        \\    const inside = struct {
        \\        fn local() u32 {
        \\            return 2;
        \\        }
        \\    };
        \\    _ = helper() + support.made() + inside.local();
        \\}
    ;
    const support = "pub fn made() u32 {\n    return 3;\n}\n";
    const declared = "pub fn given() u32 {\n    return 4;\n}\n";
    var project = try glint.Project.init(std.testing.allocator, &.{
        .{ .name = "root.zig", .bytes = root },
        .{ .name = "support.zig", .bytes = support },
        .{ .name = "declared.zig", .bytes = declared, .classification = .@"test" },
    }, &.{.{ .from = 0, .spelling = "support.zig", .target = 1 }}, .{});
    defer project.deinit();
    const checking: glint.ProjectRule = .{ .definition = rule.definition, .check = productionFunctions };
    var report = try glint.runConfigured(std.testing.allocator, &project, configuration(.report), .{ .project_rules = &.{checking} });
    defer report.deinit();
    // The private helper only the test calls and the file only the test imports are production;
    // the function inside the test block and the input classified test are not.
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: helper and made, nothing else.
    for (report.diagnostics) |found| try std.testing.expect(found.span.file != project.sources[2].id);
    try std.testing.expect(report.diagnostics[0].span.file != report.diagnostics[1].span.file);
}
