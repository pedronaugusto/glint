//! A project file's policy, resolved into glint's configuration: the caller's levels, the rules
//! the run's packages declare at their own defaults (a ban a finding, hygiene a report), each
//! amended by the in-repo configuration as far as the caller's floor lets it, and the code options
//! the configuration and the repository's glint.json write. glint is told a floor, never whose it
//! is: a refusal names the floor (docs/design.md, "The program contract").
const Policy = @This();

const std = @import("std");
const Rules = @import("Rule.zig");
const Rule = Rules.Rule;
const Config = Rules.Config;
const Contract = @import("Contract.zig");
const Report = @import("Report.zig");
const ProjectFile = Contract.ProjectFile;
const Weight = ProjectFile.Weight;

/// glint's configuration for a file nothing sets apart (`forFile` sets each file's). Its
/// `paths_from` and `names_from` are the caller's to set: the seams name paths from the root.
base: Config,
/// The rules whose findings fail the run although glint reports them (weight `finding`).
findings: []const Rule,
/// The bans that hold what the package ships: the caller's and every rule a package declares.
shipped_bans: []const Rule,
/// Shipped bans fail (the release tier).
release: bool,
/// What resolving allowed and the report says: a level below its default where no floor holds
/// it, a glint.json setting a project file does not read. One line each.
notes: []const []const u8,

pub const Error = error{ OutOfMemory, Refused } || std.Io.Writer.Error;

/// The policy `project` asks, over the rules `definitions` holds (glint's and the run's
/// packages', `Runner.packageRules`), with `repo_options` the glint.json `policy.repo_options`
/// names as it is written, which the caller reads (none where the floor refuses one, `refuses`).
/// Each refusal is one line on `problems`, all of them written before `Refused`: a setting glint
/// does not honour is a gate that is not there.
pub fn resolve(a: std.mem.Allocator, project: ProjectFile, repo_options: ?Contract.Written, definitions: []const Rules.Definition, problems: *std.Io.Writer) Error!Policy {
    const policy = project.policy;
    var r: Resolver = .{ .a = a, .definitions = definitions, .problems = problems };
    var table: std.ArrayList(Entry) = .empty;
    try r.defaults(&table, policy);
    try r.packages(&table, policy.floor);
    var base = Config.none();
    base.strict_suppressions = policy.strict_suppressions;
    base.metrics = policy.metrics;
    base.fact_budget = policy.fact_budget;
    base.disallowed = policy.disallowed;
    if (policy.repo_options) |path| try r.repository(&base, path, repo_options, policy.floor);
    if (policy.config) |written| {
        try r.amend(&table, written.rules orelse &.{});
        try r.options(&base, "policy.config", written, .config);
    }
    const shipped = try r.shippedBans(policy.shipped_bans);
    var findings: std.ArrayList(Rule) = .empty;
    const selections = try a.alloc(Config.Selection, table.items.len);
    for (table.items, selections) |entry, *selection| {
        if (entry.weight == .finding) try findings.append(a, entry.rule);
        selection.* = .{ .rule = entry.rule, .level = levelOf(entry.weight) };
    }
    base.selections = selections;
    for (base.seams) |seam| for (seam.rules) |name| {
        if (Rules.parseConfigured(name, definitions) == null) try r.refuseName("seams", name);
    };
    base.validate() catch try r.refuse("policy: not a configuration glint runs: a disallowed declaration lacks its reason or replacement or names a symbol with dots, or a seam or test input names both a file and a directory or neither", .{});
    if (r.refused) return error.Refused;
    return .{ .base = base, .findings = findings.items, .shipped_bans = shipped, .release = project.release, .notes = r.notes.items };
}

/// Whether the caller's floor refuses a repository's glint.json, which is then not read.
pub fn refuses(policy: ProjectFile.Policy) bool {
    const floor = policy.floor orelse return false;
    return floor.refuse_repo_options;
}

/// glint's configuration for `file`: the base with its function ceiling (P003 off where it has
/// none) and exceptions, the shipped bans off where the package does not ship it, and the rules of
/// its text off where it is its upstream's copy.
pub fn forFile(policy: Policy, a: std.mem.Allocator, file: ProjectFile.File) error{OutOfMemory}!Config {
    var config = policy.base;
    if (file.max_function_lines) |lines| config.max_function_lines = lines;
    config.function_exceptions = file.function_exceptions;
    const selections = try a.dupe(Config.Selection, policy.base.selections);
    for (selections) |*selection| {
        const rule = selection.rule;
        const unbudgeted = rule == .P003 and file.max_function_lines == null;
        const unshipped = !file.ships and std.mem.findScalar(Rule, policy.shipped_bans, rule) != null;
        if (unbudgeted or unshipped or (file.vendored != null and upstreamText(rule))) selection.level = .off;
    }
    config.selections = selections;
    return config;
}

/// What a finding means to the caller: whether it fails the run, whether a ban that holds what
/// the package ships made it, and whether it is carried (a shipped ban's, in a file the caller
/// verified as its upstream's copy: that verification is its reason, and it fails nothing).
pub const Verdict = Report.Verdict;

/// The verdict on a finding of `rule` at `level` in `file`.
pub fn verdict(policy: Policy, rule: Rule, level: Config.Level, file: ProjectFile.File) Verdict {
    const shipped_ban = std.mem.findScalar(Rule, policy.shipped_bans, rule) != null;
    const carried = shipped_ban and file.vendored != null;
    const finding = std.mem.findScalar(Rule, policy.findings, rule) != null;
    return .{ .fails = !carried and (level == .gate or finding or (policy.release and shipped_ban)), .shipped_ban = shipped_ban, .carried = carried };
}

/// A rule at its weight, and the weight a floor holds it at, if one does.
const Entry = struct { rule: Rule, weight: Weight, floor: ?Weight = null };

const Resolver = struct {
    a: std.mem.Allocator,
    definitions: []const Rules.Definition,
    problems: *std.Io.Writer,
    notes: std.ArrayList([]const u8) = .empty,
    refused: bool = false,

    fn refuse(r: *Resolver, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
        r.refused = true;
        try r.problems.print(format ++ "\n", args);
    }

    /// A name no rule of the run has, in glint's words for it (`Rule.Removed`).
    fn refuseName(r: *Resolver, where: []const u8, name: []const u8) std.Io.Writer.Error!void {
        r.refused = true;
        try r.problems.print("{s}: ", .{where});
        try Rules.Removed.refuse(r.problems, name);
        try r.problems.writeByte('\n');
    }

    fn note(r: *Resolver, comptime format: []const u8, args: anytype) error{OutOfMemory}!void {
        try r.notes.append(r.a, try r.a.print(format, args));
    }

    fn nameOf(r: *const Resolver, rule: Rule) []const u8 {
        return (Rules.definition(rule, r.definitions) orelse return "a rule of no definition").name;
    }

    /// The caller's levels, each a rule of glint's own; then what its floor holds, which no level
    /// may already be under.
    fn defaults(r: *Resolver, table: *std.ArrayList(Entry), policy: ProjectFile.Policy) Error!void {
        for (policy.levels, 0..) |entry, i| {
            if (listed(policy.levels[0..i], entry.rule)) {
                try r.refuse("policy.levels: {s} is listed twice", .{entry.rule});
                continue;
            }
            const rule = Rule.parse(entry.rule) orelse {
                try r.refuseName("policy.levels", entry.rule);
                continue;
            };
            try table.append(r.a, .{ .rule = rule, .weight = entry.weight });
        }
        const floor = policy.floor orelse return;
        for (floor.rules, 0..) |held, i| {
            if (listed(floor.rules[0..i], held.rule)) {
                try r.refuse("policy.floor: {s} is listed twice", .{held.rule});
                continue;
            }
            const rule = Rule.parse(held.rule) orelse {
                try r.refuseName("policy.floor", held.rule);
                continue;
            };
            const entry = find(table.items, rule) orelse {
                try r.refuse("policy.floor: {s} is held at {t}, and `policy.levels` does not weigh it", .{ held.rule, held.weight });
                continue;
            };
            if (rank(held.weight) > rank(entry.weight)) try r.refuse("policy.floor: {s} is held at {t}, above its level ({t})", .{ held.rule, held.weight, entry.weight });
            entry.floor = held.weight;
        }
    }

    /// Each rule a package of the run declares, at its own default: a ban a finding, hygiene a
    /// report, off where it is off unasked; held there where the floor holds packages' defaults.
    fn packages(r: *Resolver, table: *std.ArrayList(Entry), floor: ?ProjectFile.Floor) error{OutOfMemory}!void {
        const held = if (floor) |f| f.package_defaults else false;
        for (r.definitions) |definition| {
            const declared = definition.declared orelse continue;
            const default: Weight = if (!declared.default) .off else if (declared.kind == .ban) .finding else .report;
            try table.append(r.a, .{ .rule = definition.id, .weight = default, .floor = if (held) default else null });
        }
    }

    /// The configuration's rules over the table: a rule it raises is raised; one it lowers is
    /// refused where the floor holds it and a note where nothing does; one the table lacks joins.
    fn amend(r: *Resolver, table: *std.ArrayList(Entry), settings: []const Contract.Configuration.Setting) Error!void {
        for (settings, 0..) |setting, i| {
            const twice = for (settings[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.id, setting.id)) break true;
            } else false;
            if (twice) {
                try r.refuse("policy.config: {s} is listed twice", .{setting.id});
                continue;
            }
            const rule = Rules.parseConfigured(setting.id, r.definitions) orelse {
                try r.refuseName("policy.config", setting.id);
                continue;
            };
            const asked = weightOf(setting.level);
            const entry = find(table.items, rule) orelse {
                try table.append(r.a, .{ .rule = rule, .weight = asked });
                continue;
            };
            if (entry.floor) |held| if (rank(asked) < rank(held)) {
                try r.refuse("policy.config: {s} is held at {t} by the caller's floor; a configuration may only raise it, not set it to {t}", .{ r.nameOf(rule), held, setting.level });
                continue;
            };
            if (rank(asked) < rank(entry.weight)) try r.note("{s} is set to {t}, below its default ({t})", .{ r.nameOf(rule), setting.level, entry.weight });
            entry.weight = asked;
        }
    }

    /// The repository's glint.json at `path`: refused where the floor refuses one, else the code
    /// options it writes.
    fn repository(r: *Resolver, base: *Config, path: []const u8, written: ?Contract.Written, floor: ?ProjectFile.Floor) Error!void {
        if (floor) |f| if (f.refuse_repo_options) {
            return r.refuse("{s}: the caller's floor refuses a repository's glint.json: its settings belong in the configuration the caller reads", .{path});
        };
        try r.options(base, path, written orelse .{}, .repository);
    }

    const Source = enum { repository, config };

    /// The code options `written` sets, onto `base`: each it writes and none it leaves out, a
    /// list joining what is there. A file's function ceiling and exceptions are the caller's, per
    /// file; so are strict suppressions and metrics, which a glint.json written for a run of its
    /// own may set, and the configuration may not.
    fn options(r: *Resolver, base: *Config, where: []const u8, written: Contract.Written, source: Source) Error!void {
        if (written.max_line_length) |n| base.max_line_length = n;
        if (written.max_parameters) |n| base.max_parameters = n;
        if (written.max_nesting) |n| base.max_nesting = n;
        if (written.max_stack_array) |n| base.max_stack_array = n;
        if (written.fact_budget) |n| base.fact_budget = n;
        if (written.disallowed) |list| base.disallowed = try std.mem.concat(r.a, Config.Disallowed, &.{ base.disallowed, list });
        if (written.seams) |list| base.seams = try std.mem.concat(r.a, Config.Seam, &.{ base.seams, list });
        if (written.test_inputs) |list| base.test_inputs = try std.mem.concat(r.a, Config.TestInput, &.{ base.test_inputs, list });
        if (written.max_function_lines != null) try r.refuse("{s}: `max_function_lines` is set per file by the caller (`files[].max_function_lines`)", .{where});
        if (written.function_exceptions != null) try r.refuse("{s}: `function_exceptions` are set per file by the caller (`files[].function_exceptions`)", .{where});
        switch (source) {
            .repository => {
                if (written.profile != null or written.rules != null) try r.note("{s}: its profile and rules are not read under a project file: the caller's levels and configuration set them", .{where});
                if (written.strict_suppressions != null or written.metrics != null) try r.note("{s}: its strict_suppressions and metrics are not read under a project file: the caller sets them", .{where});
            },
            .config => {
                if (written.profile != null) try r.refuse("{s}: `profile` is not read under a project file: the caller's levels are the defaults, which `rules` amends", .{where});
                if (written.strict_suppressions != null) try r.refuse("{s}: `strict_suppressions` is the caller's (`policy.strict_suppressions`)", .{where});
                if (written.metrics != null) try r.refuse("{s}: `metrics` is the caller's (`policy.metrics`)", .{where});
            },
        }
    }

    /// The caller's shipped bans, then every rule a package of the run declares.
    fn shippedBans(r: *Resolver, names: []const []const u8) Error![]const Rule {
        var out: std.ArrayList(Rule) = .empty;
        for (names) |name| {
            const rule = Rules.parseConfigured(name, r.definitions) orelse {
                try r.refuseName("policy.shipped_bans", name);
                continue;
            };
            try out.append(r.a, rule);
        }
        for (r.definitions) |definition| if (definition.declared != null) try out.append(r.a, definition.id);
        return out.items;
    }
};

fn listed(entries: []const ProjectFile.LevelEntry, rule: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.rule, rule)) return true;
    return false;
}

fn find(table: []Entry, rule: Rule) ?*Entry {
    for (table) |*entry| if (entry.rule == rule) return entry;
    return null;
}

/// A rule whose finding only an edit of the file's text clears, and which claims nothing of what
/// the code does: the house style and dead code. An upstream's copy leaves these off, its text
/// being its upstream's.
fn upstreamText(rule: Rule) bool {
    // A package's rule (an id from 1000) holds what the code does, whoever wrote the text.
    if (@backingInt(rule) >= 1000) return false;
    return switch (rule) {
        .P003, .Z016, .D001, .Z013 => true,
        else => rule.group() == .zig_style,
    };
}

/// How much a weight holds a package to: off, reported, a finding, gated.
fn rank(weight: Weight) u2 {
    return switch (weight) {
        .off => 0,
        .report => 1,
        .finding => 2,
        .gate => 3,
    };
}

/// A finding is reported, and fails the run by the policy's `findings`.
fn levelOf(weight: Weight) Config.Level {
    return switch (weight) {
        .gate => .gate,
        .finding, .report => .report,
        .off => .off,
    };
}

fn weightOf(level: Config.Level) Weight {
    return switch (level) {
        .gate => .gate,
        .report => .report,
        .off => .off,
    };
}

const testing = std.testing;

/// aegis's A007, as a run that reaches aegis reads it: a ban on by default.
const aegis_ban: Rules.Definition = .{ .id = @fromBackingInt(1000), .name = "A007", .group = .family_policy, .purpose = "governed state", .declared = .{ .package = "aegis", .kind = .ban, .reads = .governed, .default = true } };

fn projectOf(policy: ProjectFile.Policy) ProjectFile {
    return .{ .version = 1, .root = ".", .files = &.{}, .policy = policy };
}

fn writtenOf(a: std.mem.Allocator, json: []const u8) !Contract.Written {
    return std.json.parseFromSliceLeaky(Contract.Written, a, json, .{});
}

fn levelIn(policy: Policy, rule: Rule) Config.Level {
    return policy.base.level(rule);
}

test "policy: the caller's levels are the defaults: a finding reports and fails, a package's ban joins as a finding, and the caller's shipped bans and the packages' rules hold what ships" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var problems: std.Io.Writer.Allocating = .init(arena.allocator());
    const policy = try resolve(arena.allocator(), projectOf(.{
        .levels = &.{ .{ .rule = "Z003", .weight = .gate }, .{ .rule = "P007", .weight = .finding }, .{ .rule = "D001", .weight = .report } },
        .shipped_bans = &.{"P007"},
        .fact_budget = 1000,
        .strict_suppressions = true,
    }), null, &.{aegis_ban}, &problems.writer);
    try testing.expectEqualStrings("", problems.written());
    try testing.expectEqual(Config.Level.gate, levelIn(policy, .Z003));
    try testing.expectEqual(Config.Level.report, levelIn(policy, .P007));
    try testing.expectEqual(Config.Level.report, levelIn(policy, aegis_ban.id));
    try testing.expectEqual(Config.Level.off, levelIn(policy, .Z026));
    try testing.expectEqualSlices(Rule, &.{ .P007, aegis_ban.id }, policy.findings);
    try testing.expectEqualSlices(Rule, &.{ .P007, aegis_ban.id }, policy.shipped_bans);
    try testing.expect(policy.base.strict_suppressions);
    try testing.expectEqual(@as(usize, 1000), policy.base.fact_budget);
    try testing.expectEqual(@as(usize, 0), policy.notes.len);
}

test "policy: with no floor a configuration sets any level, and each below its default is a note; under a floor, below it is refused in the floor's words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const levels: []const ProjectFile.LevelEntry = &.{ .{ .rule = "Z026", .weight = .gate }, .{ .rule = "D001", .weight = .report } };
    const config: Contract.Written = .{ .rules = &.{ .{ .id = "Z026", .level = .report }, .{ .id = "D001", .level = .gate }, .{ .id = "Z045", .level = .report } } };
    var problems: std.Io.Writer.Allocating = .init(a);
    const open = try resolve(a, projectOf(.{ .levels = levels, .shipped_bans = &.{}, .fact_budget = 1, .config = config }), null, &.{}, &problems.writer);
    try testing.expectEqualStrings("", problems.written());
    try testing.expectEqual(Config.Level.report, levelIn(open, .Z026));
    try testing.expectEqual(Config.Level.gate, levelIn(open, .D001));
    // A rule the levels do not weigh joins at the level asked.
    try testing.expectEqual(Config.Level.report, levelIn(open, .Z045));
    try testing.expectEqual(@as(usize, 1), open.notes.len);
    try testing.expectEqualStrings("Z026 is set to report, below its default (gate)", open.notes[0]);

    const floor: ProjectFile.Floor = .{ .rules = &.{.{ .rule = "Z026", .weight = .gate }} };
    try testing.expectError(error.Refused, resolve(a, projectOf(.{ .levels = levels, .floor = floor, .shipped_bans = &.{}, .fact_budget = 1, .config = config }), null, &.{}, &problems.writer));
    try testing.expectEqualStrings("policy.config: Z026 is held at gate by the caller's floor; a configuration may only raise it, not set it to report\n", problems.written());
}

test "policy: a package's rule is held at its default where the floor holds packages' defaults, and a name no rule of the run has is refused in glint's words" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problems: std.Io.Writer.Allocating = .init(a);
    const lowered: Contract.Written = .{ .rules = &.{.{ .id = "A007", .level = .off }} };
    try testing.expectError(error.Refused, resolve(a, projectOf(.{ .levels = &.{}, .floor = .{ .package_defaults = true }, .shipped_bans = &.{}, .fact_budget = 1, .config = lowered }), null, &.{aegis_ban}, &problems.writer));
    try testing.expectEqualStrings("policy.config: A007 is held at finding by the caller's floor; a configuration may only raise it, not set it to off\n", problems.written());
    // Raised, it gates.
    const raised: Contract.Written = .{ .rules = &.{.{ .id = "A007", .level = .gate }} };
    const policy = try resolve(a, projectOf(.{ .levels = &.{}, .floor = .{ .package_defaults = true }, .shipped_bans = &.{}, .fact_budget = 1, .config = raised }), null, &.{aegis_ban}, &problems.writer);
    try testing.expectEqual(Config.Level.gate, levelIn(policy, aegis_ban.id));
    try testing.expectEqual(@as(usize, 0), policy.findings.len);
    // Where no package of the run declares it, A007 is aegis's, and A019 is P007 now.
    problems.clearRetainingCapacity();
    const gone: Contract.Written = .{ .rules = &.{ .{ .id = "A007", .level = .gate }, .{ .id = "A019", .level = .gate } } };
    try testing.expectError(error.Refused, resolve(a, projectOf(.{ .levels = &.{.{ .rule = "Q1", .weight = .gate }}, .shipped_bans = &.{}, .fact_budget = 1, .config = gone }), null, &.{}, &problems.writer));
    try testing.expectEqualStrings(
        "policy.levels: `Q1` is not a rule glint has\n" ++
            "policy.config: `A007` is not glint's since 0.8: aegis declares it in its `lint_rules`, a rule wherever the program reaches aegis; remove it where it does not\n" ++
            "policy.config: `A019` was removed in glint 0.8: its check is `P007`, name that\n",
        problems.written(),
    );
}

test "policy: a repository's glint.json lends the code options it writes, unless the floor refuses one; a file's ceiling is the caller's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problems: std.Io.Writer.Allocating = .init(a);
    const json =
        \\{"profile": "reviewed", "max_line_length": 140, "seams": [{"file": "src/io.zig", "rules": ["P007"], "reason": "the I/O seam"}],
        \\ "disallowed": [{"source": "std", "declaration": "debug.print", "reason": "r", "replacement": "x"}]}
    ;
    const base: ProjectFile.Policy = .{ .levels = &.{.{ .rule = "P007", .weight = .finding }}, .shipped_bans = &.{}, .fact_budget = 1, .repo_options = "glint.json", .config = .{ .max_line_length = 120 } };
    const policy = try resolve(a, projectOf(base), try writtenOf(a, json), &.{}, &problems.writer);
    try testing.expectEqualStrings("", problems.written());
    // The configuration's option over the repository's; the lists join.
    try testing.expectEqual(@as(u32, 120), policy.base.max_line_length);
    try testing.expectEqual(@as(usize, 1), policy.base.seams.len);
    try testing.expectEqual(@as(usize, 1), policy.base.disallowed.len);
    try testing.expectEqualStrings("glint.json: its profile and rules are not read under a project file: the caller's levels and configuration set them", policy.notes[0]);

    var refusing = base;
    refusing.floor = .{ .refuse_repo_options = true };
    try testing.expect(refuses(refusing));
    try testing.expectError(error.Refused, resolve(a, projectOf(refusing), null, &.{}, &problems.writer));
    try testing.expectEqualStrings("glint.json: the caller's floor refuses a repository's glint.json: its settings belong in the configuration the caller reads\n", problems.written());

    problems.clearRetainingCapacity();
    try testing.expectError(error.Refused, resolve(a, projectOf(base), try writtenOf(a, "{\"max_function_lines\": 80, \"seams\": [{\"file\": \"a.zig\", \"rules\": [\"A099\"], \"reason\": \"r\"}]}"), &.{}, &problems.writer));
    try testing.expectEqualStrings("glint.json: `max_function_lines` is set per file by the caller (`files[].max_function_lines`)\nseams: `A099` is not a rule glint has\n", problems.written());
}

test "policy: each file's configuration: no ceiling turns P003 off, a file not shipped is free of the shipped bans, an upstream's copy of its text rules, and a shipped ban there is carried" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var problems: std.Io.Writer.Allocating = .init(a);
    const policy = try resolve(a, .{ .version = 1, .root = ".", .release = true, .files = &.{}, .policy = .{
        .levels = &.{ .{ .rule = "P003", .weight = .report }, .{ .rule = "P007", .weight = .report }, .{ .rule = "Z001", .weight = .report }, .{ .rule = "Z026", .weight = .gate } },
        .shipped_bans = &.{"P007"},
        .fact_budget = 1,
    } }, null, &.{}, &problems.writer);
    const shipped: ProjectFile.File = .{ .path = "src/a.zig", .kind = .production, .ships = true, .max_function_lines = 80 };
    const script: ProjectFile.File = .{ .path = "ci/x.zig", .kind = .support, .ships = false, .max_function_lines = null };
    const copy: ProjectFile.File = .{ .path = "src/fiat.zig", .kind = .production, .ships = true, .max_function_lines = 80, .vendored = .{ .upstream = "fiat-crypto", .verification = "byte-equal to the generator's output" } };

    const own = try policy.forFile(a, shipped);
    try testing.expectEqual(@as(u32, 80), own.max_function_lines);
    try testing.expect(own.has(.P003) and own.has(.P007) and own.has(.Z001));
    const tool = try policy.forFile(a, script);
    try testing.expect(!tool.has(.P003) and !tool.has(.P007) and tool.has(.Z026));
    const upstream = try policy.forFile(a, copy);
    try testing.expect(!upstream.has(.P003) and !upstream.has(.Z001) and upstream.has(.P007));
    // The base is untouched by any file's.
    try testing.expect(policy.base.has(.P003));

    // Under the release tier a shipped ban fails; in the upstream's copy it is carried.
    try testing.expectEqual(Verdict{ .fails = true, .shipped_ban = true, .carried = false }, policy.verdict(.P007, .report, shipped));
    try testing.expectEqual(Verdict{ .fails = false, .shipped_ban = true, .carried = true }, policy.verdict(.P007, .report, copy));
    try testing.expectEqual(Verdict{ .fails = false, .shipped_ban = false, .carried = false }, policy.verdict(.Z001, .report, shipped));
    try testing.expectEqual(Verdict{ .fails = true, .shipped_ban = false, .carried = false }, policy.verdict(.Z026, .gate, copy));
}
