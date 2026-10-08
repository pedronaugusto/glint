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

    pub fn group(self: Rule) Group {
        return switch (self) {
            .Z003, .Z011, .Z013 => .correctness,
            .Z012, .Z016, .Z026 => .family_policy,
            else => .zig_style,
        };
    }
    pub fn purpose(self: Rule) []const u8 {
        return switch (self) {
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
    enabled: [34]bool = core,
    max_line_length: u32 = 100,
    strict_suppressions: bool = false,
    fact_budget: usize = 100_000,

    const core = blk: {
        var selection: [34]bool = @splat(false);
        selection[3] = true;
        selection[13] = true;
        break :blk selection;
    };

    /// Unknown/removed IDs cannot silently enter a library configuration.
    pub fn validate(self: Config) error{InvalidSelection}!void {
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
        self.enabled[@backingInt(rule)] = enabled; // safe: enum identities index their owning frozen tables without narrowing.
    }
    /// Whether a rule was selected.
    pub fn has(self: Config, rule: Rule) bool {
        return self.enabled[@backingInt(rule)]; // safe: enum identities index their owning frozen tables without narrowing.
    }
};

test "review inventory excludes removed identities without compatibility aliases" {
    try std.testing.expectEqual(@as(usize, 14), std.meta.tags(Rule).len); // safe: explicit compile-time type selection; the value is representable in that type.
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
