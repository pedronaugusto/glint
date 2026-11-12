//! Reviewed rules. Removed identities are rejected, never aliased or silently enabled.
pub const Group = enum { correctness, zig_style, family_policy };
const std = @import("std");
pub const Rule = enum(u16) {
    Z001 = 1,
    Z003 = 3,
    Z005 = 5,
    Z006 = 6,
    Z009 = 9,
    Z011 = 11,
    Z012 = 12,
    Z013 = 13,
    Z014 = 14,
    Z016 = 16,
    Z024 = 24,
    Z026 = 26,
    Z031 = 31,
    Z032 = 32,
    Z034 = 34,
    P003 = 42,
    P005 = 44,
    P006 = 45,
    D001 = 46,
    // The breadth rules (glint 0.8). Their numbers meet the ones above (Z042 and P003, Z046 and
    // D001), so their ids are 100 + the number for a Z, 200 + the number for a P.
    Z035 = 135,
    Z036 = 136,
    Z037 = 137,
    Z038 = 138,
    Z039 = 139,
    Z040 = 140,
    Z041 = 141,
    Z042 = 142,
    Z043 = 143,
    Z044 = 144,
    Z045 = 145,
    Z046 = 146,
    Z047 = 147,
    Z048 = 148,
    Z049 = 149,
    Z051 = 151,
    Z052 = 152,
    Z053 = 153,
    Z054 = 154,
    Z055 = 155,
    Z056 = 156,
    P007 = 207,
    P008 = 208,
    P009 = 209,
    P010 = 210,
    P011 = 211,
    P012 = 212,
    P013 = 213,
    _,

    pub fn group(self: Rule) Group {
        return switch (self) {
            .Z003, .Z011, .Z013, .Z026, .Z034, .D001 => .correctness,
            .Z035, .Z036, .Z037, .Z038, .Z039, .Z041, .Z043, .Z044, .Z047, .Z048, .Z049, .Z051, .Z052, .Z053, .Z054 => .correctness,
            .Z012, .Z016, .P003, .P005, .P006 => .family_policy,
            .P007, .P008, .P009, .P010, .P011, .P012, .P013 => .family_policy,
            else => .zig_style,
        };
    }
    pub fn purpose(self: Rule) []const u8 {
        return switch (self) {
            .P003 => "function exceeds the configured reading budget",
            .P005 => "production debug print violates explicit project policy",
            .P006 => "resolved declaration is disallowed by project policy",
            .D001 => "private declaration its file names nowhere",
            .Z003 => "syntax incompatibility",
            .Z034 => "operator precedence the next Zig refuses",
            .Z011 => "deprecated API migration",
            .Z013 => "dead private import binding",
            .Z012 => "public API type cannot be named by its caller",
            .Z026 => "discarded error needs a site-written reason",
            .Z016 => "assertion failure localization (advisory)",
            .Z035 => "operation on two operands written alike",
            .Z036 => "if whose condition or branches decide nothing",
            .Z037 => "narrow arithmetic widened only after it can overflow",
            .Z038 => "local array larger than the configured stack budget",
            .Z039 => "comparison its operand's type decides",
            .Z040 => "expect of an equality that expectEqual says better",
            .Z041 => "partial read or write count discarded",
            .Z042 => "expectEqual with the expected value second",
            .Z043 => "loop that leaves on its first pass",
            .Z044 => "function that recurses before anything can stop it",
            .Z045 => "public declaration without a doc comment",
            .Z046 => "field or tag not named as the style guide names it",
            .Z047 => "condition written as a literal",
            .Z048 => "float compared to a decimal literal it cannot hold exactly",
            .Z049 => "comparison with NaN",
            .Z051 => "loop counter narrower than its bound",
            .Z052 => "constant initialised to undefined",
            .Z053 => "errdefer in a function that cannot return an error",
            .Z054 => "build module that ignores -Doptimize or -Dtarget",
            .Z055 => "public function taking anytype",
            .Z056 => "empty if or else body with no comment",
            .P007 => "operation Zig leaves unchecked, outside a seam",
            .P008 => "identifying integers of one type that one may pass for another",
            .P009 => "pointer into the frame carried out of the call",
            .P010 => "unwrap that traps where the optional is null",
            .P011 => "undefined outside a test",
            .P012 => "debugging left in the code",
            .P013 => "function over the configured parameter or nesting limit",
            else => "Zig style naming or readability (no runtime bug claimed)",
        };
    }
    /// Whether a run leaves the rule off until it is asked for by name: the opt-in rules no
    /// profile turns on.
    pub fn optIn(self: Rule) bool {
        return switch (self) {
            .Z045, .Z046, .Z054, .Z055, .Z056, .P010, .P011, .P012, .P013 => true,
            else => false,
        };
    }
    pub fn parse(name: []const u8) ?Rule {
        return std.meta.stringToEnum(Rule, name);
    }
};

/// The rules a configuration turns on, by id: glint's own (below 1000) and the rules packages
/// declare in their `lint_rules` (`PackageRules`, from 1000), every id a `Rule` can hold.
pub const Set = std.bit_set.Array(usize, 1 << 16);

/// Explicit rule selection. Only the two inspected inherited core rules default on.
pub const Config = struct {
    enabled: Set = core,
    /// Whether each rule a package declares on by default (`.default = true`) runs unless the
    /// configuration sets it: off for a profile of none and for a run of named rules (`--only`).
    package_defaults: bool = true,
    max_line_length: u32 = 100,
    strict_suppressions: bool = false,
    max_function_lines: u32 = 120,
    /// The parameters and the nesting depth P013 allows a function.
    max_parameters: u32 = 7,
    max_nesting: u32 = 5,
    /// The bytes Z038 allows one local array.
    max_stack_array: u64 = 64 * 1024,
    function_exceptions: []const FunctionException = &.{},
    disallowed: []const Disallowed = &.{},
    selections: []const Selection = &.{},
    fact_budget: usize = 100_000,
    /// Count each selected file's functions and assertion calls into the report.
    metrics: bool = false,
    /// Where the project declares the rules it names are not reported, with one written reason:
    /// a file, or a directory (`module`). The report counts each one's sites per rule
    /// (`Report.seams`), and one whose rules ran and found nothing in it is stale.
    seams: []const Seam = &.{},
    /// The inputs that are test code beside `test` blocks: a path glob or a directory. Every rule
    /// reads them as test code (`RuleContext.inTest`), whatever the caller classified; the report
    /// counts each one's files, and one matching none is stale.
    test_inputs: []const TestInput = &.{},
    /// The directory `seams` and `test_inputs` name paths from (the configuration file's): an
    /// input named under it is matched by its path from there.
    paths_from: ?[]const u8 = null,

    pub const Level = enum { off, report, gate };
    pub const Selection = struct { rule: Rule, level: Level };
    /// One seam: exactly one of `file` (an input's path, or a glob of them) and `module` (a
    /// directory, every input under it), the rules it is a seam for by name, and why.
    pub const Seam = struct { file: ?[]const u8 = null, module: ?[]const u8 = null, rules: []const []const u8, reason: []const u8 };
    /// One test input entry: exactly one of `path` (an input's path, or a glob of them) and
    /// `module` (a directory).
    pub const TestInput = struct { path: ?[]const u8 = null, module: ?[]const u8 = null };

    /// The first seam that holds the input named `name` for the rule named `rule`.
    pub fn seamOf(self: Config, name: []const u8, rule: []const u8) ?usize {
        const relative = self.fromRoot(name);
        for (self.seams, 0..) |seam, i| {
            if (!covers(seam.file, seam.module, relative)) continue;
            for (seam.rules) |each| if (std.mem.eql(u8, each, rule)) return i;
        }
        return null;
    }
    /// The first test input entry that holds the input named `name`.
    pub fn testInput(self: Config, name: []const u8) ?usize {
        const relative = self.fromRoot(name);
        for (self.test_inputs, 0..) |entry, i| if (covers(entry.path, entry.module, relative)) return i;
        return null;
    }
    /// `name` from `paths_from` where it lies under it; else as given.
    fn fromRoot(self: Config, name: []const u8) []const u8 {
        const root = std.mem.trimEnd(u8, self.paths_from orelse return name, "/");
        if (name.len > root.len and std.mem.startsWith(u8, name, root) and name[root.len] == '/') return name[root.len + 1 ..];
        return name;
    }
    pub const FunctionException = struct { function: []const u8, lines: u32, reason: []const u8 };
    pub const Disallowed = struct {
        source: ?[]const u8 = null,
        declaration: []const u8,
        reason: []const u8,
        replacement: []const u8,
        /// `production` leaves out test code: tests and test blocks.
        scope: enum { all, production } = .all,
        /// The packages that own the declaration (`Project.Input.package`): their files are
        /// where it is meant to be used, so a site in one is not governed by this entry.
        owners: []const []const u8 = &.{},
    };

    const core = blk: {
        var selection: Set = .empty;
        selection.set(3);
        selection.set(13);
        break :blk selection;
    };

    /// Unknown/removed IDs cannot silently enter a library configuration.
    pub fn validate(self: Config) error{InvalidSelection}!void {
        for (self.function_exceptions, 0..) |exception, i| {
            for (self.function_exceptions[0..i]) |earlier| if (std.mem.eql(u8, exception.function, earlier.function)) return error.InvalidSelection;
            if (exception.function.len == 0) return error.InvalidSelection;
        }
        for (self.function_exceptions) |exception| if (std.mem.trim(u8, exception.reason, " \t\r\n").len == 0 or exception.lines == 0) return error.InvalidSelection;
        for (self.disallowed) |entry| {
            if (std.mem.trim(u8, entry.reason, " \t\r\n").len == 0 or std.mem.trim(u8, entry.replacement, " \t\r\n").len == 0) return error.InvalidSelection;
            for (entry.owners) |owner| if (std.mem.trim(u8, owner, " \t\r\n").len == 0) return error.InvalidSelection;
            if (entry.source) |source| {
                if (std.mem.trim(u8, source, " \t\r\n").len == 0) return error.InvalidSelection;
                var parts = std.mem.splitScalar(u8, entry.declaration, '.');
                while (parts.next()) |part| if (part.len == 0) return error.InvalidSelection;
            } else if (entry.declaration.len == 0 or std.mem.findScalar(u8, entry.declaration, '.') != null) return error.InvalidSelection;
        }
        for (self.selections, 0..) |selection, i| for (self.selections[0..i]) |earlier| if (selection.rule == earlier.rule) return error.InvalidSelection;
        for (self.seams) |seam| {
            if ((seam.file == null) == (seam.module == null) or seam.rules.len == 0) return error.InvalidSelection;
            if (std.mem.trim(u8, seam.reason, " \t\r\n").len == 0) return error.InvalidSelection;
            for (seam.rules) |rule| if (rule.len == 0) return error.InvalidSelection;
        }
        for (self.test_inputs) |entry| if ((entry.path == null) == (entry.module == null)) return error.InvalidSelection;
        // An id below 1000 is glint's own and must be one it has; one from 1000 is a package's,
        // which the run checks against the rules the packages declare (Runner).
        var on = self.enabled.iterator(.{});
        while (on.next()) |index| {
            if (index >= 1000) continue;
            var known = false;
            for (std.meta.tags(Rule)) |rule| if (@backingInt(rule) == index) {
                known = true;
            };
            if (!known) return error.InvalidSelection;
        }
    }
    /// An empty selection for callers migrating explicit policy.
    pub fn none() Config {
        return .{ .enabled = .empty, .package_defaults = false };
    }
    /// All reviewed rules for reporting but the opt-in ones. A caller decides which groups gate.
    pub fn reviewed() Config {
        var config = none();
        for (std.meta.tags(Rule)) |rule| config.set(rule, !rule.optIn());
        config.package_defaults = true;
        return config;
    }
    /// Selects a stable rule ID.
    pub fn set(self: *Config, rule: Rule, enabled: bool) void {
        self.enabled.setValue(@backingInt(rule), enabled);
    }
    /// A required semantic fact for a gating rule cannot be ignored or suppressed.
    pub fn level(self: Config, rule: Rule) Level {
        for (self.selections) |selection| if (selection.rule == rule) return selection.level;
        return if (self.has(rule)) .report else .off;
    }
    /// Explicit family reporting profile. Adoption and gating belong to the caller.
    /// Whether a rule was selected.
    pub fn has(self: Config, rule: Rule) bool {
        for (self.selections) |selection| if (selection.rule == rule) return selection.level != .off;
        return self.enabled.isSet(@backingInt(rule));
    }
};

/// Whether an input named `name` is the `file` (a path, or a glob: `*` within a part, `**`
/// across parts) or lies under the directory `module`.
fn covers(file: ?[]const u8, module: ?[]const u8, name: []const u8) bool {
    if (file) |pattern| return glob(pattern, name);
    const dir = std.mem.trimEnd(u8, module orelse return false, "/");
    return name.len > dir.len and std.mem.startsWith(u8, name, dir) and name[dir.len] == '/';
}

/// A path glob: `**` matches any run of characters, `*` any within one path part, `?` one
/// character other than `/`; anything else itself.
pub fn glob(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    if (std.mem.startsWith(u8, pattern, "**")) {
        var rest = pattern[2..];
        if (std.mem.startsWith(u8, rest, "/")) rest = rest[1..];
        for (0..name.len + 1) |i| if (glob(rest, name[i..])) return true;
        return false;
    }
    switch (pattern[0]) {
        '*' => {
            for (0..name.len + 1) |i| {
                if (glob(pattern[1..], name[i..])) return true;
                if (i < name.len and name[i] == '/') return false;
            }
            return false;
        },
        '?' => return name.len != 0 and name[0] != '/' and glob(pattern[1..], name[1..]),
        else => return name.len != 0 and name[0] == pattern[0] and glob(pattern[1..], name[1..]),
    }
}

test "a seam holds a file, a glob of files or a directory for the rules it names, and a test input entry a path glob or a directory" {
    const config: Config = .{
        .seams = &.{
            .{ .file = "src/uring.zig", .rules = &.{ "A007", "P007" }, .reason = "kernel-shared ring words" },
            .{ .module = "src/backend/", .rules = &.{"A007"}, .reason = "the backends are the runtime's seam" },
        },
        .test_inputs = &.{ .{ .path = "src/**/*_test.zig" }, .{ .module = "src/testing" } },
    };
    try config.validate();
    try std.testing.expectEqual(@as(?usize, 0), config.seamOf("src/uring.zig", "P007"));
    try std.testing.expectEqual(@as(?usize, null), config.seamOf("src/uring.zig", "A009"));
    try std.testing.expectEqual(@as(?usize, 1), config.seamOf("src/backend/kqueue/poll.zig", "A007"));
    try std.testing.expectEqual(@as(?usize, null), config.seamOf("src/backend.zig", "A007"));
    try std.testing.expectEqual(@as(?usize, 0), config.testInput("src/odb/pack_test.zig"));
    try std.testing.expectEqual(@as(?usize, 1), config.testInput("src/testing/server.zig"));
    try std.testing.expectEqual(@as(?usize, null), config.testInput("src/odb/pack.zig"));
    // An input named by its full path is matched by its path from the configuration's directory.
    var rooted = config;
    rooted.paths_from = "/work/pkg/";
    try std.testing.expectEqual(@as(?usize, 0), rooted.seamOf("/work/pkg/src/uring.zig", "A007"));
    try std.testing.expectEqual(@as(?usize, null), rooted.seamOf("/elsewhere/src/uring.zig", "A007"));
    // A seam with no reason, both a file and a directory, or no rule is refused.
    const bad = [_]Config.Seam{ .{ .file = "a.zig", .rules = &.{"A007"}, .reason = " " }, .{ .file = "a.zig", .module = "src", .rules = &.{"A007"}, .reason = "r" }, .{ .file = "a.zig", .rules = &.{}, .reason = "r" } };
    for (bad) |seam| try std.testing.expectError(error.InvalidSelection, (Config{ .seams = &.{seam} }).validate());
}

test "review inventory excludes removed identities without compatibility aliases" {
    try std.testing.expectEqual(@as(usize, 47), std.meta.tags(Rule).len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqual(null, Rule.parse("Z008"));
    // Folded into P007, P009 and Z026, never aliased.
    for ([_][]const u8{ "P001", "P002", "P004", "E001" }) |id| try std.testing.expectEqual(null, Rule.parse(id));
    try std.testing.expectEqual(null, Rule.parse("Z013-extra"));
    for ([_][]const u8{ "Z002", "Z004", "Z019", "Z020", "Z021", "Z022", "Z029", "Z030", "Z033" }) |id| try std.testing.expectEqual(null, Rule.parse(id));
    try std.testing.expect(!@as(Config, .{}).has(.Z011)); // safe: explicit compile-time type selection; the value is representable in that type.
}

test "a configuration turns on any rule id, a package's from 1000 among them, with no table to outgrow" {
    var config = Config.none();
    const declared: Rule = @fromBackingInt(2000);
    config.set(declared, true);
    config.set(.D001, true);
    try std.testing.expect(config.has(declared) and config.has(.D001) and !config.has(.Z003));
    // Whether a package declares it is the run's to check, against the packages' rules.
    try config.validate();
    config.set(declared, false);
    try std.testing.expect(!config.has(declared));
}

test "the reviewed profile turns on every rule but the opt-in ones, which a selection by name turns on" {
    const reviewed = Config.reviewed();
    try std.testing.expect(reviewed.has(.Z035) and reviewed.has(.Z053) and reviewed.has(.Z026));
    for ([_]Rule{ .Z045, .Z046, .Z054, .Z055, .Z056, .P010, .P011, .P012, .P013 }) |rule| try std.testing.expect(!reviewed.has(rule));
    var asked = reviewed;
    asked.set(.P013, true);
    try std.testing.expect(asked.has(.P013));
    try asked.validate();
}

test "inventory rejects unknown selection slots through public configuration" {
    var config = Config.none();
    config.enabled.set(8);
    try std.testing.expectError(error.InvalidSelection, config.validate());
}

/// A ban reports every site of what it names outside a seam; a hygiene rule only what it is
/// certain of (glint-0.8-shape, "The principle").
pub const Kind = enum { ban, hygiene };
/// What a package's rule reads of its `lint_rules`: the governed types' internal fields, their
/// exits, or the `.replaces` entries naming it.
pub const Reads = enum { governed, exits, replaces };

/// Stable metadata for both built-in and compiled project rules.
pub const Definition = struct {
    id: Rule,
    name: []const u8,
    group: Group,
    purpose: []const u8,
    version: u32 = 1,
    report_only: bool = false,
    /// Where a package declares the rule in its `lint_rules`; null for glint's own and a
    /// caller's compiled rules.
    declared: ?Declared = null,

    pub const Declared = struct {
        /// The package, as its `build.zig.zon` names it.
        package: []const u8,
        kind: Kind,
        reads: Reads,
        /// Whether a run selects it unasked.
        default: bool,
    };
};
/// Metadata is shared by suppression, reporting and project rule registration.
pub fn definition(id: Rule, project: []const Definition) ?Definition {
    for (std.meta.tags(Rule)) |builtin| if (builtin == id) return .{ .id = id, .name = @tagName(builtin), .group = builtin.group(), .purpose = builtin.purpose(), .version = 3 };
    for (project) |rule| if (rule.id == id) return rule;
    return null;
}
pub fn parseConfigured(name: []const u8, project: []const Definition) ?Rule {
    if (Rule.parse(name)) |id| return id;
    for (project) |rule| if (std.mem.eql(u8, name, rule.name)) return rule.id;
    return null;
}

/// A rule id glint 0.7 had that 0.8 does not, and what a configuration naming it does now. A
/// removed id is never an alias: it is refused, and the refusal says this.
pub const Removed = struct {
    id: []const u8,
    now: union(enum) {
        /// Gone with no successor: the configuration drops it.
        removed,
        /// Its check is the rule of this id now.
        renamed: []const u8,
        /// The package of this name declares a rule of the same id in its `lint_rules`: a rule
        /// of the run wherever the program reaches that package, and of no other run.
        declared: []const u8,
    },

    /// The refusal of `name` where no rule of the run has it, with what to write instead
    /// where 0.8 removed it.
    pub fn refuse(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
        const gone = removed(name) orelse return w.print("`{s}` is not a rule glint has", .{name});
        try gone.write(w);
    }

    /// What a configuration naming this id is told.
    pub fn write(gone: Removed, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (gone.now) {
            .removed => try w.print("`{s}` was removed in glint 0.8: remove it", .{gone.id}),
            .renamed => |id| try w.print("`{s}` was removed in glint 0.8: its check is `{s}`, name that", .{ gone.id, id }),
            .declared => |package| try w.print("`{s}` is not glint's since 0.8: {s} declares it in its `lint_rules`, a rule wherever the program reaches {s}; remove it where it does not", .{ gone.id, package, package }),
        }
    }
};

/// Every rule id 0.7 had that 0.8 removed, as CHANGELOG's 0.8 section lists them.
pub const removed_rules = [_]Removed{
    .{ .id = "A001", .now = .{ .declared = "aegis" } },
    .{ .id = "A002", .now = .removed },
    .{ .id = "A003", .now = .removed },
    .{ .id = "A004", .now = .{ .declared = "aegis" } },
    .{ .id = "A005", .now = .removed },
    .{ .id = "A006", .now = .removed },
    .{ .id = "A007", .now = .{ .declared = "aegis" } },
    .{ .id = "A008", .now = .{ .declared = "aegis" } },
    .{ .id = "A009", .now = .{ .declared = "aegis" } },
    .{ .id = "A010", .now = .removed },
    .{ .id = "A011", .now = .{ .declared = "aegis" } },
    .{ .id = "A012", .now = .{ .declared = "aegis" } },
    .{ .id = "A013", .now = .{ .declared = "aegis" } },
    .{ .id = "A014", .now = .{ .renamed = "P009" } },
    .{ .id = "A015", .now = .{ .declared = "aegis" } },
    .{ .id = "A016", .now = .{ .renamed = "P008" } },
    .{ .id = "A017", .now = .removed },
    .{ .id = "A018", .now = .removed },
    .{ .id = "A019", .now = .{ .renamed = "P007" } },
    .{ .id = "A020", .now = .removed },
    .{ .id = "A021", .now = .{ .declared = "aegis" } },
};

/// What 0.8 did with the rule id `name`, where it removed it.
pub fn removed(name: []const u8) ?Removed {
    for (removed_rules) |gone| if (std.mem.eql(u8, gone.id, name)) return gone;
    return null;
}

test "a removed rule's refusal says it was removed in 0.8 and what to write instead" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try Removed.refuse(&w, "A002");
    try std.testing.expectEqualStrings("`A002` was removed in glint 0.8: remove it", w.buffered());
    w.end = 0;
    try Removed.refuse(&w, "A007");
    try std.testing.expectEqualStrings("`A007` is not glint's since 0.8: aegis declares it in its `lint_rules`, a rule wherever the program reaches aegis; remove it where it does not", w.buffered());
    w.end = 0;
    try Removed.refuse(&w, "Z008");
    try std.testing.expectEqualStrings("`Z008` is not a rule glint has", w.buffered());
    // A renamed id names its successor.
    w.end = 0;
    try Removed.refuse(&w, "A019");
    try std.testing.expectEqualStrings("`A019` was removed in glint 0.8: its check is `P007`, name that", w.buffered());
    // No row names a rule glint has, nor names one twice; a successor is a rule glint has.
    for (removed_rules, 0..) |gone, i| {
        try std.testing.expectEqual(@as(?Rule, null), Rule.parse(gone.id));
        for (removed_rules[0..i]) |earlier| try std.testing.expect(!std.mem.eql(u8, earlier.id, gone.id));
        switch (gone.now) {
            .renamed => |id| try std.testing.expect(Rule.parse(id) != null),
            .removed, .declared => {},
        }
    }
}
