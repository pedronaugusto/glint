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
const Contract = @import("AegisContract.zig");

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
/// Where the rules' findings come in; each callback gets the runner back from it.
sink: Context.Sink = .{ .diagnostic = sinkDiagnostic, .coverage = sinkCoverage, .config = sinkConfig },
escapes: std.ArrayList(Report.Escape) = .empty,
malformed: std.ArrayList(Report.Malformed) = .empty,
/// What each of the current file's aegis escapes covered, by its index in `suppressions`.
covered: std.array_hash_map.Auto(usize, std.ArrayList(Report.Covered)) = .empty,
complete: bool = true,
definitions: []const rules.Definition = &.{},
files: []const FileConfig = &.{},
/// The file whose rules run; set before each file's run, and read only during it.
file: Project.FileId = undefined,

pub const RunError = Suppression.ParseError || Context.Error || std.Io.Cancelable;
pub const Options = struct {
    project_rules: []const Context.Rule = &.{},
    files: []const FileConfig = &.{},
    /// The caller's `Io`, asked for a cancel before each file's rules run:
    /// a canceled run is `Canceled`. Null: none is asked, and a canceller
    /// waits for the whole project.
    io: ?std.Io = null,
};
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
        // An id of another project.
        if (@backingInt(setting.file) >= project.count()) return error.InvalidHandle;
        for (options.files[0..i]) |earlier| if (setting.file == earlier.file) return error.InvalidSelection;
    }
    const definitions = try a.alloc(rules.Definition, options.project_rules.len);
    for (options.project_rules, 0..) |rule, i| {
        definitions[i] = rule.definition;
        definitions[i].name = try a.dupe(u8, rule.definition.name);
        definitions[i].purpose = try a.dupe(u8, rule.definition.purpose);
    }
    try validateRules(config, definitions);
    var runner: Runner = .{ .a = a, .project = project, .config = config, .base = config, .files = options.files, .definitions = definitions, .facts = .{ .project = project, .gpa = a, .known = &Contract.known, .remaining = config.fact_budget } };
    defer runner.facts.deinit();
    var metrics: std.ArrayList(Report.Metrics.File) = .empty;
    var total: Report.Metrics.Counts = .{};
    for (project.sources) |*source| {
        if (!source.input.selected) continue;
        if (options.io) |io| try io.checkCancel();
        runner.file = source.id;
        runner.config = config;
        for (options.files) |setting| if (setting.file == runner.file) {
            runner.config = setting.config;
        };
        // Each file's analysis has its own budget: work a scan of the program did for an
        // earlier file is kept, and charged to that file.
        runner.facts.remaining = runner.config.fact_budget;
        try runner.config.validate();
        try validateRules(runner.config, definitions);
        const file = &source.file;
        var malformed: std.ArrayList(Suppression.Malformed) = .empty;
        runner.suppressions = try Suppression.parseConfigured(a, file, definitions, &malformed);
        for (malformed.items) |entry| {
            runner.complete = false;
            const start = entry.comment.start;
            try runner.malformed.append(a, .{ .why = entry.why, .span = .{ .file = runner.file, .start = start, .end = entry.comment.end, .line = entry.comment.line + 1, .column = file.column(start) } });
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
            const lowered_coverage = source.model.lowered_coverage;
            try runner.coverage.append(a, .{ .file = runner.file, .reason = if (lowered_coverage == .budget_exhausted) .budget_exhausted else .unsupported, .detail = if (file.zir == null) "required semantic lowering was not requested" else "std-ZIR declaration references are indexed only through supported structured bodies; lexical references are indexed separately" });
            if (lowered_coverage == .budget_exhausted) runner.complete = false;
        }
        var context: Context = .{ .allocator = a, .project = project, .file = runner.file, .config = runner.config, .facts = &runner.facts, .definitions = definitions, .sink = &runner.sink };
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
        // stale when every rule it names ran and none of their findings stood on the line (an
        // escape in the older form, every pack rule).
        for (runner.suppressions, 0..) |suppression, i| {
            const start = suppression.comment.start;
            const span: Report.Span = .{ .file = runner.file, .start = start, .end = suppression.comment.end, .line = suppression.comment.line + 1, .column = file.column(start) };
            if (suppression.escape) |reason| {
                // An escape in the older form covers what any pack rule finds on its line, a
                // finding added later too: it is read so the fix can name what it covers, and
                // the run that reads one is incomplete.
                if (suppression.unnamed) {
                    runner.complete = false;
                    try runner.malformed.append(a, .{ .why = "an aegis escape names the rules it covers: `// aegis: <reason>(<rule>, ...): <why>`", .span = span });
                }
                if (suppression.used) {
                    try runner.escapes.append(a, .{ .span = span, .reason = @tagName(reason), .why = suppression.reason, .covered = runner.covered.get(i).?.items });
                } else if (runner.escapeRan(suppression, options.project_rules)) {
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
        if (runner.facts.remaining == 0) {
            runner.complete = false;
            try runner.coverage.append(a, .{ .file = runner.file, .reason = .budget_exhausted, .detail = "semantic fact budget exhausted" });
        }
    }
    if (config.strict_suppressions and runner.stale.items.len != 0) runner.complete = false;
    std.mem.sort(Report.Diagnostic, runner.diagnostics.items, project, diagnosticLess);
    return .{ .arena = arena, .snapshot = project.identity, .diagnostics = runner.diagnostics.items, .coverage = runner.coverage.items, .suppressed = runner.suppressed, .stale_suppressions = runner.stale.items.len, .stale = runner.stale.items, .escapes = runner.escapes.items, .malformed = runner.malformed.items, .complete = runner.complete, .metrics = if (config.metrics) .{ .files = metrics.items, .total = total } else null };
}

/// Whether a rule of the aegis pack ran on the current file.
/// Whether every rule an escape covers ran: those it names, or, in the older form, the pack.
fn escapeRan(self: *const Runner, escape: Suppression, project_rules: []const Context.Rule) bool {
    if (!escape.unnamed) {
        for (escape.covers[0..escape.covers_len]) |rule| if (!self.config.has(rule)) return false;
        return true;
    }
    for (project_rules) |rule| if (rule.definition.exception == .aegis and !self.config.has(rule.definition.id)) return false;
    return true;
}

fn diagnosticLess(project: *const Project, lhs: Report.Diagnostic, rhs: Report.Diagnostic) bool {
    const order = std.mem.order(u8, project.at(lhs.span.file).input.name, project.at(rhs.span.file).input.name);
    if (order != .eq) return order == .lt;
    if (lhs.span.start != rhs.span.start) return lhs.span.start < rhs.span.start;
    return @backingInt(lhs.rule) < @backingInt(rhs.rule); // safe: enum identities index their owning frozen tables without narrowing.
}

fn emitRelated(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span, fix: []const Report.Edit) Context.Error!void {
    if (!self.config.has(rule)) return;
    const file = &self.project.at(self.file).file;
    const line = file.line(start);
    const metadata = rules.definition(rule, self.definitions) orelse return error.InvalidSelection;
    const span: Report.Span = .{ .file = self.file, .start = start, .end = end, .line = line + 1, .column = file.column(start) };
    // An escape in the older form names no rule it was judged for: what it covers is recorded
    // for the fix to name, and stays a finding, its fix held back, until its rules are named.
    var held = false;
    for (self.suppressions, 0..) |*suppression, i| {
        if (!try suppression.matches(rule, metadata.exception == .aegis, line, start)) continue;
        if (suppression.escape != null) {
            const entry = try self.covered.getOrPut(self.a, i);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.a, .{ .name = metadata.name, .span = span });
        }
        if (suppression.unnamed) {
            held = true;
            break;
        }
        self.suppressed += 1;
        return;
    }
    try self.diagnostics.append(self.a, .{ .rule = rule, .name = metadata.name, .rule_version = metadata.version, .class = switch (metadata.group) {
        .correctness => .correctness,
        .zig_style => .zig_style,
        .family_policy => .family_policy,
    }, .level = self.config.level(rule), .severity = if (rule == .Z003) .@"error" else .warning, .span = span, .message = try self.a.dupe(u8, message), .related = try self.a.dupe(Report.Span, related), .bug_class = metadata.purpose, .fix = if (fix.len != 0 and !held) try Fix.copy(self.a, fix) else &.{} });
}

fn sinkDiagnostic(sink: *Context.Sink, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span, fix: []const Report.Edit) Context.Error!void {
    const runner: *Runner = @fieldParentPtr("sink", sink);
    try runner.emitRelated(rule, start, end, message, related, fix);
}
fn sinkConfig(sink: *Context.Sink, file: Project.FileId) rules.Config {
    const runner: *Runner = @fieldParentPtr("sink", sink);
    for (runner.files) |setting| if (setting.file == file) return setting.config;
    return runner.base;
}
fn sinkCoverage(sink: *Context.Sink, coverage: Report.Coverage) Context.Error!void {
    const runner: *Runner = @fieldParentPtr("sink", sink);
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
