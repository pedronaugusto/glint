//! Selected rules share one frozen project and one fact resolver.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const Suppression = @import("Suppression.zig");
const Runner = @This();

a: std.mem.Allocator,
project: *const Project,
config: rules.Config,
facts: Facts,
diagnostics: std.ArrayList(Report.Diagnostic) = .empty,
coverage: std.ArrayList(Report.Coverage) = .empty,
suppressions: []Suppression = &.{},
suppressed: usize = 0,
stale: usize = 0,
complete: bool = true,
file: Project.FileId = @fromBackingInt(0),

pub const RunError = Suppression.ParseError || std.mem.Allocator.Error;

pub fn run(gpa: std.mem.Allocator, project: *const Project, config: rules.Config) RunError!Report {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var runner: Runner = .{ .a = a, .project = project, .config = config, .facts = .{ .project = project, .gpa = a, .remaining = config.fact_budget } };
    defer runner.facts.deinit();
    for (project.inputs, 0..) |input, index| {
        if (!input.selected) continue;
        runner.file = @fromBackingInt(@intCast(index));
        const file = &project.files[index];
        runner.suppressions = try Suppression.parse(a, file);
        try runner.coverage.append(a, .{ .file = runner.file, .reason = switch (file.status) {
            .parsed => .parsed,
            .invalid_syntax => .invalid_syntax,
            .invalid_lowering => .invalid_lowering,
            .budget_exhausted => .budget_exhausted,
        } });
        try runner.parser();
        if (file.status == .parsed) try runner.unusedImports();
        if (file.status == .invalid_lowering or file.status == .budget_exhausted) runner.complete = false;
        for (runner.suppressions) |suppression| if (!suppression.used) {
            runner.stale += 1;
        };
    }
    if (config.strict_suppressions and runner.stale != 0) runner.complete = false;
    std.mem.sort(Report.Diagnostic, runner.diagnostics.items, project, diagnosticLess);
    return .{ .arena = arena, .diagnostics = runner.diagnostics.items, .coverage = runner.coverage.items, .suppressed = runner.suppressed, .stale_suppressions = runner.stale, .complete = runner.complete };
}

fn diagnosticLess(project: *const Project, lhs: Report.Diagnostic, rhs: Report.Diagnostic) bool {
    const order = std.mem.order(u8, project.inputs[@backingInt(lhs.span.file)].name, project.inputs[@backingInt(rhs.span.file)].name);
    if (order != .eq) return order == .lt;
    if (lhs.span.start != rhs.span.start) return lhs.span.start < rhs.span.start;
    return @backingInt(lhs.rule) < @backingInt(rhs.rule);
}

fn emit(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8) RunError!void {
    if (!self.config.has(rule)) return;
    const file = &self.project.files[@backingInt(self.file)];
    const line = file.line(start);
    for (self.suppressions) |*suppression| if (suppression.matches(rule, line)) {
        self.suppressed += 1;
        return;
    };
    try self.diagnostics.append(self.a, .{ .rule = rule, .class = switch (rule) {
        .Z003 => .correctness,
        .Z013 => .hygiene,
        .Z007, .Z026 => .suspicious,
        else => .style,
    }, .severity = if (rule == .Z003) .@"error" else .warning, .span = .{ .file = self.file, .start = start, .end = end, .line = line + 1, .column = start - file.lines[line] + 1 }, .message = message, .bug_class = switch (rule) {
        .Z003 => "syntax incompatibility",
        .Z013 => "dead private import binding",
        else => "selected compatibility policy",
    } });
}

fn at(self: *Runner, rule: rules.Rule, token: std.zig.Ast.TokenIndex, message: []const u8) RunError!void {
    const tree = &self.project.files[@backingInt(self.file)].tree;
    const start = tree.tokenStart(token);
    try self.emit(rule, start, start + @as(u32, @intCast(tree.tokenSlice(token).len)), message);
}

fn parser(self: *Runner) RunError!void {
    if (!self.config.has(.Z003)) return;
    const file = &self.project.files[@backingInt(self.file)];
    for (file.tree.errors) |err| {
        if (err.is_note) continue;
        var writer: std.Io.Writer.Allocating = .init(self.a);
        file.tree.renderError(err, &writer.writer) catch return error.OutOfMemory;
        const offset = file.tree.tokenStart(err.token) + file.tree.errorOffset(err);
        try self.emit(.Z003, offset, offset, try writer.toOwnedSlice());
    }
}

fn unusedImports(self: *Runner) RunError!void {
    if (!self.config.has(.Z013)) return;
    const file_index = @backingInt(self.file);
    const tree = &self.project.files[file_index].tree;
    for (self.project.models[file_index].declarations) |decl| {
        if (decl.kind != .variable or decl.public or decl.exported or decl.references != 0) continue;
        const variable = tree.fullVarDecl(decl.node).?;
        const value = variable.ast.init_node.unwrap() orelse continue;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const args = Facts.builtinArgs(tree, value, &buffer);
        if (args.len == 1 and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(value)), "@import")) {
            try self.at(.Z013, decl.token, try self.a.print("unused private import '{s}'", .{decl.name}));
        }
    }
}

test "core diagnostics distinguish invalid parsing and unused imports" {
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "syntax", .bytes = "const x = ;" },
        .{ .name = "bindings", .bytes = "const dep = @import(\"dep\"); const used = @import(\"used\"); pub fn f() void { _ = used; }" },
    }, &.{}, .{});
    defer project.deinit();
    var report = try run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len);
    try std.testing.expectEqual(rules.Rule.Z013, report.diagnostics[0].rule);
    try std.testing.expectEqual(rules.Rule.Z003, report.diagnostics[1].rule);
}

test "core diagnostics suppression cannot hide incomplete lowering" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "root", .bytes = "fn f(x: u8) void {}" }}, &.{}, .{});
    defer project.deinit();
    var report = try run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expect(!report.complete);
    try std.testing.expectEqual(.invalid_lowering, report.coverage[0].reason);
}
