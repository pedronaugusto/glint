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
    P001 = 40,
    P002 = 41,
    P003 = 42,
    P004 = 43,
    P005 = 44,
    P006 = 45,
    D001 = 46,
    _,

    pub fn group(self: Rule) Group {
        return switch (self) {
            .Z003, .Z011, .Z013, .D001 => .correctness,
            .Z012, .Z016, .Z026, .P001, .P002, .P003, .P004, .P005, .P006 => .family_policy,
            else => .zig_style,
        };
    }
    pub fn purpose(self: Rule) []const u8 {
        return switch (self) {
            .P001 => "cast requires a written boundary reason",
            .P002 => "runtime safety disabled without a measured-site reason",
            .P003 => "function exceeds the configured reading budget",
            .P004 => "catch unreachable requires a written invariant",
            .P005 => "production debug print violates explicit project policy",
            .P006 => "resolved declaration is disallowed by project policy",
            .D001 => "dead private declaration after complete reference resolution",
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
    cast_scope: enum { all, production } = .all,
    casts: enum { all, pointer } = .all,
    function_exceptions: []const FunctionException = &.{},
    disallowed: []const Disallowed = &.{},
    selections: []const Selection = &.{},
    fact_budget: usize = 100_000,

    pub const Level = enum { off, report, gate };
    pub const Selection = struct { rule: Rule, level: Level };
    pub const FunctionException = struct { function: []const u8, lines: u32, reason: []const u8 };
    pub const Disallowed = struct { source: []const u8, declaration: []const u8, reason: []const u8, replacement: []const u8 };

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
            if (std.mem.trim(u8, entry.source, " \t\r\n").len == 0 or std.mem.trim(u8, entry.reason, " \t\r\n").len == 0 or std.mem.trim(u8, entry.replacement, " \t\r\n").len == 0) return error.InvalidSelection;
            var parts = std.mem.splitScalar(u8, entry.declaration, '.');
            while (parts.next()) |part| if (part.len == 0) return error.InvalidSelection;
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
        std.debug.assert(@backingInt(rule) < self.enabled.len); // safe: caller uses the fixed built-in selection table.
        self.enabled[@backingInt(rule)] = enabled; // safe: enum identities index their owning frozen tables without narrowing.
    }
    /// A required semantic fact for a gating rule cannot be ignored or suppressed.
    pub fn level(self: Config, rule: Rule) Level {
        for (self.selections) |selection| if (selection.rule == rule) return selection.level;
        return if (self.has(rule)) .report else .off;
    }
    /// Explicit family reporting profile. Adoption and gating belong to the caller.
    pub fn family() Config {
        var result = reviewed();
        result.set(.D001, false); // Deadness is enabled only after the caller accepts admitted semantic coverage.
        return result;
    }
    /// Whether a rule was selected.
    pub fn has(self: Config, rule: Rule) bool {
        for (self.selections) |selection| if (selection.rule == rule) return selection.level != .off;
        return @backingInt(rule) < self.enabled.len and self.enabled[@backingInt(rule)]; // safe: enum identities index their owning frozen tables without narrowing.
    }
};

test "review inventory excludes removed identities without compatibility aliases" {
    try std.testing.expectEqual(@as(usize, 21), std.meta.tags(Rule).len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expect(Rule.parse("Z008") == null);
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
