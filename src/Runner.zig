//! Selected rules share one frozen project and one fact resolver.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const Suppression = @import("Suppression.zig");
const Runner = @This();
const Context = @import("RuleContext.zig");
const Usage = @import("Usage.zig");
const Builtins = @import("Builtins.zig");

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
definitions: []const rules.Definition = &.{},
file: Project.FileId = Project.FileId.fromRaw(0), // safe: validated file identities and budgeted std source indexes fit u32.

pub const RunError = Suppression.ParseError || Context.Error;
pub const Options = struct { project_rules: []const Context.Rule = &.{}, files: []const FileConfig = &.{} };
pub const FileConfig = struct { file: Project.FileId, config: rules.Config };

pub fn run(gpa: std.mem.Allocator, project: *const Project, config: rules.Config) RunError!Report {
    return runConfigured(gpa, project, config, .{});
}

pub fn runConfigured(gpa: std.mem.Allocator, project: *const Project, config: rules.Config, options: Options) RunError!Report {
    try config.validate();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    for (options.files, 0..) |setting, i| {
        if (setting.file.raw() >= project.count()) return error.InvalidHandle;
        for (options.files[0..i]) |earlier| if (setting.file.eql(earlier.file)) return error.InvalidSelection;
    }
    const definitions = try a.alloc(rules.Definition, options.project_rules.len);
    for (options.project_rules, 0..) |rule, i| {
        definitions[i] = rule.definition;
        definitions[i].name = try a.dupe(u8, rule.definition.name);
        definitions[i].purpose = try a.dupe(u8, rule.definition.purpose);
    }
    try validateRules(config, definitions);
    var runner: Runner = .{ .a = a, .project = project, .config = config, .definitions = definitions, .facts = .{ .project = project, .gpa = a, .remaining = config.fact_budget } };
    defer runner.facts.deinit();
    var needs_usage = config.has(.D001);
    for (options.files) |setting| if (setting.config.has(.D001)) {
        needs_usage = true;
    };
    var usage: ?Usage = if (needs_usage) try Usage.init(gpa, project, &runner.facts) else null;
    defer if (usage) |*value| value.deinit();
    for (project.inputs, 0..) |input, index| {
        if (!input.selected) continue;
        runner.file = Project.FileId.fromRaw(@intCast(index)); // safe: validated file identities and budgeted std source indexes fit u32.
        runner.config = config;
        for (options.files) |setting| if (setting.file.eql(runner.file)) {
            runner.config = setting.config;
        };
        try runner.config.validate();
        try validateRules(runner.config, definitions);
        const file = &project.files[index];
        runner.suppressions = try Suppression.parseConfigured(a, file, definitions);
        try runner.coverage.append(a, .{ .file = runner.file, .reason = switch (file.status) {
            .parsed => .parsed,
            .invalid_syntax => .invalid_syntax,
            .invalid_lowering => .invalid_lowering,
            .budget_exhausted => .budget_exhausted,
        }, .detail = switch (file.status) {
            .parsed => "std AST and AstGen/ZIR lowered; no compiler type checking or generic evaluation",
            .invalid_syntax => "std parser rejected source; semantic rules skipped",
            .invalid_lowering => "std AstGen rejected source; semantic rules skipped",
            .budget_exhausted => "front-end work budget exhausted; semantic rules skipped",
        } });
        if (file.status == .parsed) {
            const lowered_coverage = project.models[index].lowered_coverage;
            try runner.coverage.append(a, .{ .file = runner.file, .reason = if (lowered_coverage == .budget_exhausted) .budget_exhausted else .unsupported, .detail = "std-ZIR declaration references are indexed only through supported structured bodies; lexical references are indexed separately" });
            if (lowered_coverage == .budget_exhausted) runner.complete = false;
        }
        var context: Context = .{ .allocator = a, .project = project, .file = runner.file, .config = runner.config, .facts = &runner.facts, .usage = if (usage) |*value| value else null, .definitions = definitions, .sink = .{ .data = &runner, .diagnostic = sinkDiagnostic, .coverage = sinkCoverage } };
        try Builtins.check(&context);
        if (file.status == .parsed) for (options.project_rules) |rule| {
            if (runner.config.has(rule.definition.id)) try rule.check(&context);
        };
        if (file.status != .parsed) runner.complete = false;
        if (runner.config.strict_suppressions) for (runner.suppressions) |suppression| if (!suppression.used) {
            runner.complete = false;
        };
        for (runner.suppressions) |suppression| if (!suppression.used) {
            runner.stale += 1;
        };
    }
    if (runner.facts.remaining == 0) {
        runner.complete = false;
        try runner.coverage.append(a, .{ .file = runner.file, .reason = .budget_exhausted, .detail = "semantic fact budget exhausted" });
    }
    if (config.strict_suppressions and runner.stale != 0) runner.complete = false;
    std.mem.sort(Report.Diagnostic, runner.diagnostics.items, project, diagnosticLess);
    return .{ .arena = arena, .snapshot = project.identity, .diagnostics = runner.diagnostics.items, .coverage = runner.coverage.items, .suppressed = runner.suppressed, .stale_suppressions = runner.stale, .complete = runner.complete };
}

fn diagnosticLess(project: *const Project, lhs: Report.Diagnostic, rhs: Report.Diagnostic) bool {
    const order = std.mem.order(u8, project.inputs[lhs.span.file.raw()].name, project.inputs[rhs.span.file.raw()].name); // safe: enum identities index their owning frozen tables without narrowing.
    if (order != .eq) return order == .lt;
    if (lhs.span.start != rhs.span.start) return lhs.span.start < rhs.span.start;
    return @backingInt(lhs.rule) < @backingInt(rhs.rule); // safe: enum identities index their owning frozen tables without narrowing.
}

fn emitRelated(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span) Context.Error!void {
    if (!self.config.has(rule)) return;
    const file = &self.project.files[self.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const line = file.line(start);
    for (self.suppressions) |*suppression| if (try suppression.matches(rule, line, start)) {
        self.suppressed += 1;
        return;
    };
    const metadata = rules.definition(rule, self.definitions) orelse return error.InvalidSelection;
    try self.diagnostics.append(self.a, .{ .rule = rule, .name = metadata.name, .rule_version = metadata.version, .class = switch (metadata.group) {
        .correctness => .correctness,
        .zig_style => .zig_style,
        .family_policy => .family_policy,
    }, .level = self.config.level(rule), .severity = if (rule == .Z003) .@"error" else .warning, .span = .{ .file = self.file, .start = start, .end = end, .line = line + 1, .column = start - file.lines[line] + 1 }, .message = try self.a.dupe(u8, message), .related = try self.a.dupe(Report.Span, related), .bug_class = metadata.purpose });
}

fn sinkDiagnostic(data: *anyopaque, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span) Context.Error!void {
    const runner: *Runner = @ptrCast(@alignCast(data)); // safe: this sink is created only from an aligned live Runner.
    try runner.emitRelated(rule, start, end, message, related);
}
fn sinkCoverage(data: *anyopaque, coverage: Report.Coverage) Context.Error!void {
    const runner: *Runner = @ptrCast(@alignCast(data)); // safe: this sink is created only from an aligned live Runner.
    var owned = coverage;
    owned.detail = try runner.a.dupe(u8, coverage.detail);
    if (coverage.rule) |id| owned.rule_name = (rules.definition(id, runner.definitions) orelse return error.InvalidSelection).name;
    try runner.coverage.append(runner.a, owned);
    if (coverage.reason == .budget_exhausted or (coverage.rule != null and runner.config.level(coverage.rule.?) == .gate)) runner.complete = false;
}
fn validateRules(config: rules.Config, definitions: []const rules.Definition) error{InvalidSelection}!void {
    for (definitions, 0..) |definition, i| {
        if (@backingInt(definition.id) < 1000 or definition.name.len == 0 or definition.name.len > 64 or definition.purpose.len == 0 or definition.version == 0) return error.InvalidSelection; // safe: IDs below 1000 are reserved for built-ins.
        if (rules.Rule.parse(definition.name) != null or std.mem.startsWith(u8, definition.name, "Z") or std.mem.startsWith(u8, definition.name, "P") or std.mem.startsWith(u8, definition.name, "D")) return error.InvalidSelection;
        for (definition.name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidSelection;
        for (definitions[0..i]) |earlier| if (earlier.id == definition.id or std.mem.eql(u8, earlier.name, definition.name)) return error.InvalidSelection;
    }
    for (config.selections) |selection| {
        const metadata = rules.definition(selection.rule, definitions) orelse return error.InvalidSelection;
        if (metadata.report_only and selection.level == .gate) return error.InvalidSelection;
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
    try std.testing.expectEqual(@as(usize, 2), report.diagnostics.len); // safe: explicit compile-time type selection; the value is representable in that type.
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
