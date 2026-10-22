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
    P003 = 42,
    P005 = 44,
    P006 = 45,
    D001 = 46,
    _,

    pub fn group(self: Rule) Group {
        return switch (self) {
            .Z003, .Z011, .Z013, .Z026, .D001 => .correctness,
            .Z012, .Z016, .P003, .P005, .P006 => .family_policy,
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
            .Z011 => "deprecated API migration",
            .Z013 => "dead private import binding",
            .Z012 => "public API type cannot be named by its caller",
            .Z026 => "discarded error needs a site-written reason",
            .Z016 => "assertion failure localization (advisory)",
            else => "Zig style naming or readability (no runtime bug claimed)",
        };
    }
    pub fn parse(name: []const u8) ?Rule {
        return std.meta.stringToEnum(Rule, name);
    }
};

/// Explicit rule selection. Only the two inspected inherited core rules default on.
pub const Config = struct {
    enabled: [64]bool = core,
    max_line_length: u32 = 100,
    strict_suppressions: bool = false,
    max_function_lines: u32 = 120,
    function_exceptions: []const FunctionException = &.{},
    disallowed: []const Disallowed = &.{},
    selections: []const Selection = &.{},
    fact_budget: usize = 100_000,
    /// Count each selected file's functions and assertion calls into the report.
    metrics: bool = false,

    pub const Level = enum { off, report, gate };
    pub const Selection = struct { rule: Rule, level: Level };
    pub const FunctionException = struct { function: []const u8, lines: u32, reason: []const u8 };
    /// A declaration a project keeps out of its code (P006), named by what a reference reaches.
    /// `source` is what `@import` takes: a `.zig` project input's name, or a module as programs
    /// import it (`std`, `aegis`), one no file imports being one nothing can reach; `declaration`
    /// is its path from there, through public namespaces from a module (`posix.fdatasync`), each
    /// per-build choice on the way read in every alternative. Null `source` names an external
    /// function by its symbol: every `extern fn` of that symbol, std's or the program's own, is
    /// the one the linker binds. A governed `extern fn` governs its symbol the same way.
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
        var selection: [64]bool = @splat(false);
        selection[3] = true;
        selection[13] = true;
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
        for (self.enabled, 0..) |enabled, index| {
            if (!enabled) continue;
            var known = false;
            for (std.meta.tags(Rule)) |rule| if (@backingInt(rule) == index) { // safe: frozen rule identities fit the selection table.
                known = true;
            };
            if (!known) return error.InvalidSelection;
        }
    }
    /// An empty selection for callers migrating explicit policy.
    pub fn none() Config {
        return .{ .enabled = @splat(false) };
    }
    /// All reviewed rules for reporting. A caller decides which groups gate.
    pub fn reviewed() Config {
        var config = none();
        for (std.meta.tags(Rule)) |rule| config.set(rule, true);
        return config;
    }
    /// Selects a stable rule ID.
    pub fn set(self: *Config, rule: Rule, enabled: bool) void {
        std.debug.assert(@backingInt(rule) < self.enabled.len); // aegis: no-danger: caller uses the fixed built-in selection table.
        self.enabled[@backingInt(rule)] = enabled; // safe: enum identities index their owning frozen tables without narrowing.
    }
    /// A required semantic fact for a gating rule cannot be ignored or suppressed.
    pub fn level(self: Config, rule: Rule) Level {
        for (self.selections) |selection| if (selection.rule == rule) return selection.level;
        return if (self.has(rule)) .report else .off;
    }
    /// Explicit family reporting profile. Adoption and gating belong to the caller.
    pub fn family() Config {
        return reviewed();
    }
    /// Whether a rule was selected.
    pub fn has(self: Config, rule: Rule) bool {
        for (self.selections) |selection| if (selection.rule == rule) return selection.level != .off;
        return @backingInt(rule) < self.enabled.len and self.enabled[@backingInt(rule)]; // safe: enum identities index their owning frozen tables without narrowing.
    }
};

test "review inventory excludes removed identities without compatibility aliases" {
    try std.testing.expectEqual(@as(usize, 18), std.meta.tags(Rule).len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(Rule.parse("Z008") == null);
    // Folded into the aegis pack's danger rules (A010, A013, A014, A019), never aliased.
    for ([_][]const u8{ "P001", "P002", "P004", "E001" }) |id| try std.testing.expect(Rule.parse(id) == null);
    try std.testing.expect(Rule.parse("Z013-extra") == null);
    for ([_][]const u8{ "Z002", "Z004", "Z019", "Z020", "Z021", "Z022", "Z029", "Z030", "Z033" }) |id| try std.testing.expect(Rule.parse(id) == null);
    try std.testing.expect(!@as(Config, .{}).has(.Z011)); // safe: explicit compile-time type selection; the value is representable in that type.
}

test "inventory rejects unknown selection slots through public configuration" {
    var config = Config.none();
    config.enabled[8] = true;
    try std.testing.expectError(error.InvalidSelection, config.validate());
}

/// Stable metadata for both built-in and compiled project rules.
pub const Definition = struct { id: Rule, name: []const u8, group: Group, purpose: []const u8, version: u32 = 1, report_only: bool = false, exception: enum { generic, aegis } = .generic };
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
