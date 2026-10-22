//! Selected rules share one frozen project and one fact resolver.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const Suppression = @import("Suppression.zig");
const Runner = @This();
const Context = @import("RuleContext.zig");
const Fix = @import("Fix.zig");
const Builtins = @import("Builtins.zig");
const Metrics = @import("Metrics.zig");

a: std.mem.Allocator,
project: *const Project,
config: rules.Config,
/// The configuration given for every file no `files` entry names.
base: rules.Config = .{},
facts: Facts,
diagnostics: std.ArrayList(Report.Diagnostic) = .empty,
coverage: std.ArrayList(Report.Coverage) = .empty,
suppressions: []Suppression = &.{},
suppressed: usize = 0,
stale: std.ArrayList(Report.Stale) = .empty,
escapes: std.ArrayList(Report.Escape) = .empty,
malformed: std.ArrayList(Report.Malformed) = .empty,
/// What each of the current file's aegis escapes covered, by its index in `suppressions`.
covered: std.array_hash_map.Auto(usize, std.ArrayList(Report.Covered)) = .empty,
complete: bool = true,
definitions: []const rules.Definition = &.{},
files: []const FileConfig = &.{},
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
        // aegis: no-danger: an identity checked against the length of the table it indexes; the comparison is the bound
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
    var runner: Runner = .{ .a = a, .project = project, .config = config, .base = config, .files = options.files, .definitions = definitions, .facts = .{ .project = project, .gpa = a, .remaining = config.fact_budget } };
    defer runner.facts.deinit();
    var metrics: std.ArrayList(Report.Metrics.File) = .empty;
    var total: Report.Metrics.Counts = .{};
    for (project.inputs, 0..) |input, index| {
        if (!input.selected) continue;
        runner.file = Project.FileId.fromRaw(@intCast(index));
        runner.config = config;
        for (options.files) |setting| if (setting.file.eql(runner.file)) {
            runner.config = setting.config;
        };
        try runner.config.validate();
        try validateRules(runner.config, definitions);
        const file = &project.files[index];
        var malformed: std.ArrayList(Suppression.Malformed) = .empty;
        runner.suppressions = try Suppression.parseConfigured(a, file, definitions, &malformed);
        for (malformed.items) |entry| {
            runner.complete = false;
            const start = entry.comment.start;
            try runner.malformed.append(a, .{ .why = entry.why, .span = .{ .file = runner.file, .start = start, .end = entry.comment.end, .line = entry.comment.line + 1, .column = start - file.lines[entry.comment.line] + 1 } });
        }
        try runner.coverage.append(a, .{ .file = runner.file, .reason = switch (file.status) {
            .parsed => .parsed,
            .invalid_syntax => .invalid_syntax,
            .invalid_lowering => .invalid_lowering,
            .budget_exhausted => .budget_exhausted,
        }, .detail = switch (file.status) {
            .parsed => if (file.zir == null) "std AST parsed; optional AstGen/ZIR lowering not requested" else "std AST and AstGen/ZIR lowered; no compiler type checking or generic evaluation",
            .invalid_syntax => "std parser rejected source; semantic rules skipped",
            .invalid_lowering => "std AstGen rejected source; semantic rules skipped",
            .budget_exhausted => "front-end work budget exhausted; semantic rules skipped",
        } });
        if (file.status == .parsed) {
            if (file.zir == null) runner.complete = false;
            const lowered_coverage = project.models[index].lowered_coverage;
            try runner.coverage.append(a, .{ .file = runner.file, .reason = if (lowered_coverage == .budget_exhausted) .budget_exhausted else .unsupported, .detail = if (file.zir == null) "required semantic lowering was not requested" else "std-ZIR declaration references are indexed only through supported structured bodies; lexical references are indexed separately" });
            if (lowered_coverage == .budget_exhausted) runner.complete = false;
        }
        var context: Context = .{ .allocator = a, .project = project, .file = runner.file, .config = runner.config, .facts = &runner.facts, .definitions = definitions, .sink = .{ .data = &runner, .diagnostic = sinkDiagnostic, .coverage = sinkCoverage, .config = sinkConfig } };
        try Builtins.check(&context);
        if (config.metrics) {
            const counts = try Metrics.count(&context);
            total.add(counts);
            try metrics.append(a, .{ .file = runner.file, .counts = counts });
        }
        if (file.status == .parsed) for (options.project_rules) |rule| {
            if (runner.config.has(rule.definition.id)) try rule.check(&context);
        };
        if (file.status != .parsed) runner.complete = false;
        // Only a rule that ran shows that a suppression of it suppresses nothing; an escape is
        // stale when a pack rule ran and none of its findings stood on the line.
        for (runner.suppressions, 0..) |suppression, i| {
            const start = suppression.comment.start;
            const span: Report.Span = .{ .file = runner.file, .start = start, .end = suppression.comment.end, .line = suppression.comment.line + 1, .column = start - file.lines[suppression.comment.line] + 1 };
            if (suppression.escape) |reason| {
                if (suppression.used) {
                    try runner.escapes.append(a, .{ .span = span, .reason = @tagName(reason), .why = suppression.reason, .covered = runner.covered.get(i).?.items });
                } else if (runner.packRan(options.project_rules)) {
                    if (runner.config.strict_suppressions) runner.complete = false;
                    try runner.stale.append(a, .{ .name = "aegis", .span = span });
                }
                continue;
            }
            const rule = suppression.rule.?;
            if (suppression.used or !runner.config.has(rule)) continue;
            if (runner.config.strict_suppressions) runner.complete = false;
            try runner.stale.append(a, .{ .name = (rules.definition(rule, definitions) orelse return error.InvalidSelection).name, .span = span });
        }
        runner.covered.clearRetainingCapacity();
    }
    if (runner.facts.remaining == 0) {
        runner.complete = false;
        try runner.coverage.append(a, .{ .file = runner.file, .reason = .budget_exhausted, .detail = "semantic fact budget exhausted" });
    }
    if (config.strict_suppressions and runner.stale.items.len != 0) runner.complete = false;
    std.mem.sort(Report.Diagnostic, runner.diagnostics.items, project, diagnosticLess);
    return .{ .arena = arena, .snapshot = project.identity, .diagnostics = runner.diagnostics.items, .coverage = runner.coverage.items, .suppressed = runner.suppressed, .stale_suppressions = runner.stale.items.len, .stale = runner.stale.items, .escapes = runner.escapes.items, .malformed = runner.malformed.items, .complete = runner.complete, .metrics = if (config.metrics) .{ .files = metrics.items, .total = total } else null };
}

/// Whether a rule of the aegis pack ran on the current file.
fn packRan(self: *const Runner, project_rules: []const Context.Rule) bool {
    for (project_rules) |rule| if (rule.definition.exception == .aegis and self.config.has(rule.definition.id)) return true;
    return false;
}

fn diagnosticLess(project: *const Project, lhs: Report.Diagnostic, rhs: Report.Diagnostic) bool {
    const order = std.mem.order(u8, project.inputs[lhs.span.file.raw()].name, project.inputs[rhs.span.file.raw()].name); // safe: enum identities index their owning frozen tables without narrowing.
    if (order != .eq) return order == .lt;
    if (lhs.span.start != rhs.span.start) return lhs.span.start < rhs.span.start;
    return @backingInt(lhs.rule) < @backingInt(rhs.rule); // safe: enum identities index their owning frozen tables without narrowing.
}

fn emitRelated(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span, fix: []const Report.Edit) Context.Error!void {
    if (!self.config.has(rule)) return;
    const file = &self.project.files[self.file.raw()]; // safe: enum identities index their owning frozen tables without narrowing.
    const line = file.line(start);
    const metadata = rules.definition(rule, self.definitions) orelse return error.InvalidSelection;
    const span: Report.Span = .{ .file = self.file, .start = start, .end = end, .line = line + 1, .column = start - file.lines[line] + 1 };
    for (self.suppressions, 0..) |*suppression, i| if (try suppression.matches(rule, metadata.exception == .aegis, line, start)) {
        self.suppressed += 1;
        if (suppression.escape != null) {
            const entry = try self.covered.getOrPut(self.a, i);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.a, .{ .name = metadata.name, .span = span });
        }
        return;
    };
    try self.diagnostics.append(self.a, .{ .rule = rule, .name = metadata.name, .rule_version = metadata.version, .class = switch (metadata.group) {
        .correctness => .correctness,
        .zig_style => .zig_style,
        .family_policy => .family_policy,
    }, .level = self.config.level(rule), .severity = if (rule == .Z003) .@"error" else .warning, .span = span, .message = try self.a.dupe(u8, message), .related = try self.a.dupe(Report.Span, related), .bug_class = metadata.purpose, .fix = if (fix.len != 0) try Fix.copy(self.a, fix) else if (metadata.exception == .aegis) try Fix.escapeOf(self.a, file, line, metadata.name, message) else &.{} });
}

fn sinkDiagnostic(data: *anyopaque, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span, fix: []const Report.Edit) Context.Error!void {
    const runner: *Runner = @ptrCast(@alignCast(data)); // aegis: internal: this sink is created only from an aligned live Runner.
    try runner.emitRelated(rule, start, end, message, related, fix);
}
fn sinkConfig(data: *anyopaque, file: Project.FileId) rules.Config {
    const runner: *Runner = @ptrCast(@alignCast(data)); // aegis: no-danger: this sink is created only from an aligned live Runner.
    for (runner.files) |setting| if (setting.file.eql(file)) return setting.config;
    return runner.base;
}
fn sinkCoverage(data: *anyopaque, coverage: Report.Coverage) Context.Error!void {
    const runner: *Runner = @ptrCast(@alignCast(data)); // aegis: internal: this sink is created only from an aligned live Runner.
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
