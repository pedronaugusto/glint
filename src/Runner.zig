//! Selected rules share one frozen project and one fact resolver.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const rules = @import("Rule.zig");
const Report = @import("Report.zig");
const Suppression = @import("Suppression.zig");
const Runner = @This();
const File = @import("File.zig");
const Context = @import("RuleContext.zig");
const Fix = @import("Fix.zig");
const Builtins = @import("Builtins.zig");
const Metrics = @import("Metrics.zig");
const PackageRules = @import("PackageRules.zig");
const Replaced = @import("Replaced.zig");
const GovernedState = @import("GovernedState.zig");

a: std.mem.Allocator,
project: *const Project,
config: rules.Config,
/// The configuration given for every file no `files` entry names.
base: rules.Config = .{},
facts: Facts,
diagnostics: std.ArrayList(Report.Diagnostic) = .empty,
/// Each finding made, by its rule, span and message: the index of its diagnostic, or null where
/// a suppression took it. A finding is one however many times its rule reaches it (a generic's
/// instances, paths to one site); the related spans of each time are its.
emitted: std.StringHashMapUnmanaged(?usize) = .empty,
errors: std.ArrayList(Report.RunError) = .empty,
suppressions: []Suppression = &.{},
suppressed: usize = 0,
stale: std.ArrayList(Report.Stale) = .empty,
/// Where the rules' findings come in; each callback gets the runner back from it.
sink: Context.Sink = .{ .diagnostic = sinkDiagnostic, .refuse = sinkRefuse, .config = sinkConfig, .suppresses = sinkSuppresses },
malformed: std.ArrayList(Report.Malformed) = .empty,
complete: bool = true,
definitions: []const rules.Definition = &.{},
files: []const FileConfig = &.{},
/// The file whose rules run; set before each file's run, and read only during it.
file: Project.FileId = undefined,
/// The sites each seam held, by seam (its index in the base configuration) and rule.
seam_sites: std.AutoHashMapUnmanaged(struct { usize, rules.Rule }, usize) = .empty,

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
    var runner: Runner = .{ .a = a, .project = project, .config = config, .base = config, .files = options.files, .facts = .{ .project = project, .gpa = a, .backing = gpa, .remaining = config.fact_budget } };
    defer runner.facts.deinit();
    // The caller's rules, then those the project's packages declare (`PackageRules.table`).
    const declared = try declaredRules(&runner.facts);
    const definitions = try a.alloc(rules.Definition, options.project_rules.len + declared.len);
    for (options.project_rules, 0..) |rule, i| definitions[i] = rule.definition;
    @memcpy(definitions[options.project_rules.len..], declared);
    // The report outlives the caller's rule table and the project's sources it names.
    for (definitions) |*definition| {
        definition.name = try a.dupe(u8, definition.name);
        definition.purpose = try a.dupe(u8, definition.purpose);
        if (definition.declared) |*declared_by| declared_by.package = try a.dupe(u8, declared_by.package);
    }
    try validateRules(config, definitions);
    runner.definitions = definitions;
    const known = definitions;
    var metrics: std.ArrayList(Report.Metrics.File) = .empty;
    var total: Report.Metrics.Counts = .{};
    // A rule's own memory for one file (`Context.allocator`), given back when the rule is done
    // with the file: what a rule keeps past that is on the run's arena, a `Facts.memo` and what
    // it holds on `Facts.gpa`, a finding copied by the sink. Its pages are unmapped when it is
    // reset, so what a rule kept by mistake faults where it is read again, not reads memory
    // given to another.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    for (project.sources) |*source| {
        // A ZON file is data, not code: no rule runs on it and it raises no run error;
        // what it holds is read through the value an import of it resolves to.
        if (!source.input.selected or source.input.kind == .zon) continue;
        if (options.io) |io| try io.checkCancel();
        runner.file = source.id;
        runner.config = try withDefaults(a, config, definitions);
        for (options.files) |setting| if (setting.file == runner.file) {
            runner.config = try withDefaults(a, setting.config, definitions);
        };
        // Each file's analysis has its own budget: work a scan of the program did for an
        // earlier file is kept, and charged to that file, unless that file's budget ran out.
        runner.facts.remaining = runner.config.fact_budget;
        try runner.config.validate();
        try validateRules(runner.config, definitions);
        const file = source.file;
        var malformed: std.ArrayList(Suppression.Malformed) = .empty;
        runner.suppressions = try Suppression.parseConfigured(a, file, known, &malformed);
        for (malformed.items) |entry| {
            runner.complete = false;
            const start = entry.comment.start;
            try runner.malformed.append(a, .{ .why = entry.why, .span = .{ .file = runner.file, .start = start, .end = entry.comment.end, .line = entry.comment.line + 1, .column = file.column(start) } });
        }
        if (file.status == .parsed) try runner.declarationProblems(file);
        switch (file.status) {
            .parsed => {},
            // The compiler would refuse it too: the bans read none of it.
            .invalid_syntax => try runner.runError(try parseError(a, file)),
            .invalid_lowering => try runner.runError("Zig's AstGen rejects it, so no rule read it: `zig ast-check` names the error"),
            .budget_exhausted => try runner.runError("its front-end work ran out of budget, so no rule read it"),
        }
        if (file.status == .parsed and source.model.lowered_coverage == .budget_exhausted) try runner.runError("its lowering ran out of budget, so no rule read all of it");
        if (file.status == .parsed and file.zir == null) try runner.runError("its semantic lowering was not asked for, so the rules that read it did not run");
        var context: Context = .{ .allocator = scratch.allocator(), .backing = gpa, .project = project, .file = runner.file, .config = runner.config, .facts = &runner.facts, .definitions = definitions, .sink = &runner.sink, .compiled = options.project_rules };
        try Builtins.check(&context);
        if (config.metrics) {
            const counts = try Metrics.count(&context);
            total.add(counts);
            try metrics.append(a, .{ .file = runner.file, .counts = counts });
        }
        _ = scratch.reset(.free_all);
        // The rules packages declare, each run by the engine of what it reads.
        if (file.status == .parsed) for (definitions) |definition| {
            const declared_by = definition.declared orelse continue;
            if (!runner.config.has(definition.id)) continue;
            switch (declared_by.reads) {
                .replaces => try Replaced.check(&context, definition),
                .governed => try GovernedState.check(&context, definition),
                .exits => try GovernedState.exits(&context, definition),
            }
            _ = scratch.reset(.free_all);
        };
        if (file.status == .parsed) for (options.project_rules) |rule| {
            if (!runner.config.has(rule.definition.id)) continue;
            try rule.check(&context);
            _ = scratch.reset(.free_all);
        };
        if (file.status != .parsed) runner.complete = false;
        try runner.judgeSuppressions(file, known);
        if (runner.facts.remaining == 0) {
            try runner.exhausted();
        } else if (runner.facts.short) {
            // A unit of solving in the file's work ran short of its own budget (`Facts.enter`):
            // it reports what it left undecided; what it built, no later file reads.
            runner.facts.forget();
        }
    }
    if (config.strict_suppressions and runner.stale.items.len != 0) runner.complete = false;
    std.mem.sort(Report.Diagnostic, runner.diagnostics.items, project, diagnosticLess);
    // Everything the report holds is made before the arena is handed to it: what is allocated
    // after the copy would be lost with the arena's earlier state.
    const seams = try runner.seamCounts(config);
    const test_inputs = try testInputCounts(a, project, config);
    return .{ .arena = arena, .snapshot = project.identity, .diagnostics = runner.diagnostics.items, .errors = runner.errors.items, .suppressed = runner.suppressed, .stale_suppressions = runner.stale.items.len, .stale = runner.stale.items, .malformed = runner.malformed.items, .complete = runner.complete, .metrics = if (config.metrics) .{ .files = metrics.items, .total = total } else null, .seams = seams, .test_inputs = test_inputs };
}

/// Each seam of `config` with the sites it held per rule; stale where every rule it names ran
/// and it held none.
fn seamCounts(runner: *const Runner, config: rules.Config) error{OutOfMemory}![]const Report.SeamCount {
    const counts = try runner.a.alloc(Report.SeamCount, config.seams.len);
    for (config.seams, counts, 0..) |seam, *count, i| {
        const per_rule = try runner.a.alloc(Report.RuleSites, seam.rules.len);
        var total: usize = 0;
        var all_ran = true;
        for (seam.rules, per_rule) |name, *sites| {
            const id = rules.parseConfigured(name, runner.definitions);
            const held = if (id) |rule| runner.seam_sites.get(.{ i, rule }) orelse 0 else 0;
            sites.* = .{ .name = name, .sites = held };
            total += held;
            all_ran = all_ran and id != null and config.has(id.?);
        }
        count.* = .{ .where = seam.file orelse seam.module.?, .reason = seam.reason, .rules = per_rule, .stale = all_ran and total == 0 };
    }
    return counts;
}

/// Each test input entry of `config` with the project's inputs it holds (the first entry that
/// holds an input counts it).
fn testInputCounts(a: std.mem.Allocator, project: *const Project, config: rules.Config) error{OutOfMemory}![]const Report.TestInputCount {
    const counts = try a.alloc(Report.TestInputCount, config.test_inputs.len);
    for (config.test_inputs, counts) |entry, *count| count.* = .{ .pattern = entry.path orelse entry.module.?, .files = 0 };
    for (project.sources) |*source| if (config.testInput(source.input.name)) |i| {
        counts[i].files += 1;
    };
    return counts;
}

/// `config` with each package rule that is on by default selected at report level, where the
/// configuration takes package defaults (`Config.package_defaults`) and sets nothing for it.
fn withDefaults(a: std.mem.Allocator, config: rules.Config, definitions: []const rules.Definition) error{OutOfMemory}!rules.Config {
    if (!config.package_defaults) return config;
    var selections: std.ArrayList(rules.Config.Selection) = .empty;
    try selections.appendSlice(a, config.selections);
    for (definitions) |definition| {
        const declared_by = definition.declared orelse continue;
        if (!declared_by.default or config.enabled.isSet(@backingInt(definition.id))) continue;
        const named = for (config.selections) |selection| {
            if (selection.rule == definition.id) break true;
        } else false;
        if (!named) try selections.append(a, .{ .rule = definition.id, .level = .report });
    }
    var effective = config;
    effective.selections = selections.items;
    return effective;
}

/// The rules the project's packages declare (`PackageRules.table`), with the ids the run gives
/// them, for a caller that resolves rule names before the run (glint's command line).
pub fn packageRules(a: std.mem.Allocator, project: *const Project) RunError![]const rules.Definition {
    var facts: Facts = .{ .project = project, .gpa = a };
    defer facts.deinit();
    return declaredRules(&facts);
}
/// Each part of a `lint_rules` this file declares that glint cannot read (PackageRules.Problem: a
/// reference that does not resolve, a rule no entry may name, ...), where it is written: the
/// declaring package's own run is incomplete, so its lint catches what would leave its rules
/// unread in the programs that import it.
fn declarationProblems(runner: *Runner, file: *const File) RunError!void {
    if (runner.facts.member(runner.facts.rootOf(runner.file), "lint_rules") == null) return;
    const declared = try PackageRules.of(&runner.facts, runner.file);
    const tree = &file.tree;
    for (declared.problems) |problem| if (problem.file == runner.file) {
        const start = tree.tokenStart(tree.firstToken(problem.node));
        runner.complete = false;
        try runner.malformed.append(runner.a, .{
            .why = try runner.a.print("lint_rules: {t}: glint does not read this part, so the programs that import this package do not know what it declares", .{problem.why}),
            .span = .{ .file = runner.file, .start = start, .end = start, .line = file.line(start) + 1, .column = file.column(start) },
        });
    };
}

/// Two packages declaring one rule id, or more rules than ids, is no selection a run can make.
fn declaredRules(facts: *Facts) RunError![]const rules.Definition {
    return PackageRules.table(facts) catch |err| switch (err) {
        error.DuplicateRule, error.TooManyRules => error.InvalidSelection,
        else => |other| other,
    };
}

/// Only a rule that ran shows that a suppression of it suppresses nothing: each rule it names that
/// ran and met no site of its on the line is stale. One for a rule this run does not enable is not
/// judged, and is counted as such.
fn judgeSuppressions(runner: *Runner, file: *const File, known: []const rules.Definition) RunError!void {
    for (runner.suppressions) |suppression| {
        const start = suppression.comment.start;
        const span: Report.Span = .{ .file = runner.file, .start = start, .end = suppression.comment.end, .line = suppression.comment.line + 1, .column = file.column(start) };
        for (suppression.names(), suppression.matched[0..suppression.named_len]) |rule, matched| {
            if (matched != null) continue;
            if (!runner.config.has(rule)) continue;
            if (runner.config.strict_suppressions) runner.complete = false;
            try runner.stale.append(runner.a, .{ .name = (rules.definition(rule, known) orelse return error.InvalidSelection).name, .span = span });
        }
    }
}

/// The file's fact budget ran out: the run is incomplete, and what its analysis kept, computed
/// short of the budget, no later file reads (`Facts.forget`).
fn exhausted(runner: *Runner) error{OutOfMemory}!void {
    runner.complete = false;
    try runner.runError("its analysis ran out of the fact budget (`fact_budget`): raise it, or split the file");
    runner.facts.forget();
}

fn diagnosticLess(project: *const Project, lhs: Report.Diagnostic, rhs: Report.Diagnostic) bool {
    const order = std.mem.order(u8, project.at(lhs.span.file).input.name, project.at(rhs.span.file).input.name);
    if (order != .eq) return order == .lt;
    if (lhs.span.start != rhs.span.start) return lhs.span.start < rhs.span.start;
    return @backingInt(lhs.rule) < @backingInt(rhs.rule); // safe: enum identities index their owning frozen tables without narrowing.
}

fn emitRelated(self: *Runner, rule: rules.Rule, start: u32, end: u32, message: []const u8, related: []const Report.Span, fix: []const Report.Edit) Context.Error!void {
    if (!self.config.has(rule)) return;
    const file = self.project.at(self.file).file;
    const line = file.line(start);
    const metadata = rules.definition(rule, self.definitions) orelse return error.InvalidSelection;
    // A site in a seam the project declares for this rule is the seam's, counted, not reported.
    if (self.config.seamOf(self.project.at(self.file).input.name, metadata.name)) |seam| {
        const held = try self.seam_sites.getOrPut(self.a, .{ seam, rule });
        held.value_ptr.* = if (held.found_existing) held.value_ptr.* + 1 else 1;
        return;
    }
    const span: Report.Span = .{ .file = self.file, .start = start, .end = end, .line = line + 1, .column = file.column(start) };
    const key = try self.a.print("{d} {d} {d} {d} {s}", .{ @backingInt(rule), @backingInt(self.file), start, end, message });
    const seen = try self.emitted.getOrPut(self.a, key);
    if (seen.found_existing) {
        const index = seen.value_ptr.* orelse return;
        const diagnostic = &self.diagnostics.items[index];
        var merged: std.ArrayList(Report.Span) = .empty;
        try merged.appendSlice(self.a, diagnostic.related);
        for (related) |each| {
            for (merged.items) |known| {
                if (std.meta.eql(known, each)) break;
            } else try merged.append(self.a, each);
        }
        diagnostic.related = merged.items;
        return;
    }
    seen.value_ptr.* = null;
    for (self.suppressions) |*suppression| {
        const matched = suppression.matches(rule, line, start) catch {
            // A second site of a rule the suppression names, on its line: the finding stands, and
            // the suppression is malformed where it is written, once.
            if (!suppression.ambiguous) {
                suppression.ambiguous = true;
                self.complete = false;
                const comment = suppression.comment;
                try self.malformed.append(self.a, .{ .why = try self.a.print("names {s} for one site, and its line holds another: give each site its own line", .{metadata.name}), .span = .{ .file = self.file, .start = comment.start, .end = comment.end, .line = comment.line + 1, .column = file.column(comment.start) } });
            }
            break;
        };
        if (!matched) continue;
        self.suppressed += 1;
        return;
    }
    seen.value_ptr.* = self.diagnostics.items.len;
    try self.diagnostics.append(self.a, .{ .rule = rule, .name = metadata.name, .rule_version = metadata.version, .class = switch (metadata.group) {
        .correctness => .correctness,
        .zig_style => .zig_style,
        .family_policy => .family_policy,
    }, .level = self.config.level(rule), .severity = if (rule == .Z003) .@"error" else .warning, .span = span, .message = try self.a.dupe(u8, message), .related = try self.a.dupe(Report.Span, related), .bug_class = metadata.purpose, .fix = if (fix.len != 0) try Fix.copy(self.a, fix) else &.{} });
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
/// Whether a finding of `rule` at `start` of the current file would be suppressed: a
/// suppression naming it on its line.
fn sinkSuppresses(sink: *Context.Sink, rule: rules.Rule, start: u32) bool {
    const runner: *Runner = @fieldParentPtr("sink", sink);
    if (!runner.config.has(rule)) return false;
    const line = runner.project.at(runner.file).file.line(start);
    for (runner.suppressions) |suppression| if (suppression.applies(rule, line)) return true;
    return false;
}
fn sinkRefuse(sink: *Context.Sink, why: []const u8) Context.Error!void {
    const runner: *Runner = @fieldParentPtr("sink", sink);
    try runner.runError(why);
}
/// A run error of the current file, once for its words: the run is incomplete.
fn runError(runner: *Runner, why: []const u8) error{OutOfMemory}!void {
    runner.complete = false;
    for (runner.errors.items) |known| if (known.file != null and known.file.? == runner.file and std.mem.eql(u8, known.why, why)) return;
    try runner.errors.append(runner.a, .{ .file = runner.file, .why = try runner.a.dupe(u8, why) });
}
/// The parser's first error, in its words, at its line and column.
fn parseError(a: std.mem.Allocator, file: *const File) error{OutOfMemory}![]const u8 {
    const tree = &file.tree;
    if (tree.errors.len == 0) return "Zig's parser rejects it, so no rule read it";
    const first = tree.errors[0];
    const at = tree.tokenLocation(0, first.token);
    var out: std.Io.Writer.Allocating = .init(a);
    out.writer.print("{d}:{d}: ", .{ at.line + 1, at.column + 1 }) catch return error.OutOfMemory;
    tree.renderError(first, &out.writer) catch return error.OutOfMemory;
    out.writer.writeAll(": Zig's parser rejects it, so no rule read it") catch return error.OutOfMemory;
    return out.written();
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
    // A rule turned on by id from 1000 is one the caller compiled in or a package declares.
    var on = config.enabled.iterator(.{});
    while (on.next()) |index| {
        if (index < 1000) continue;
        if (rules.definition(@fromBackingInt(@as(u16, @intCast(index))), definitions) == null) return error.InvalidSelection;
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
    try std.testing.expectEqual(@as(usize, 1), report.errors.len);
}

test "a ZON file is data: no rule runs on it and it stops no run" {
    var project = try Project.init(std.testing.allocator, &.{.{ .name = "k.zon", .bytes = ".{ .bytes = .{ 1, 2 } }", .kind = .zon }}, &.{}, .{});
    defer project.deinit();
    var report = try run(std.testing.allocator, &project, .{});
    defer report.deinit();
    try std.testing.expect(report.complete);
    try std.testing.expectEqual(0, report.errors.len);
    try std.testing.expectEqual(0, report.diagnostics.len);
}

test "the rules a package declares join the run's rules: selectable by id, and an id no rule has is refused" {
    var project = try Project.init(std.testing.allocator, &.{
        .{ .name = "root", .bytes = "pub fn f() void {}\n" },
        .{ .name = "pkg/root.zig", .package = "pkg", .fingerprint = 7, .selected = false, .bytes = "pub const lint_rules = .{ .version = 2, .rules = .{.{ .id = .X001, .name = \"raw\", .kind = .ban, .reads = .replaces, .default = true, .purpose = \"std's raw form\" }} };\n" },
    }, &.{}, .{});
    defer project.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const declared = try packageRules(arena.allocator(), &project);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    try std.testing.expectEqualStrings("X001", declared[0].name);
    try std.testing.expect(rules.parseConfigured("X001", declared).? == declared[0].id);
    var report = try runConfigured(std.testing.allocator, &project, .{ .enabled = .empty, .selections = &.{.{ .rule = declared[0].id, .level = .report }} }, .{});
    defer report.deinit();
    try std.testing.expect(report.complete);
    var config: rules.Config = .{ .enabled = .empty };
    config.set(@fromBackingInt(2005), true);
    try std.testing.expectError(error.InvalidSelection, runConfigured(std.testing.allocator, &project, config, .{}));
}
