//! Stable compatibility inventory. Porting a rule does not adopt a default.
const std = @import("std");
pub const Rule = enum(u16) {
    Z001 = 1,
    Z002 = 2,
    Z003 = 3,
    Z004 = 4,
    Z005 = 5,
    Z006 = 6,
    Z007 = 7,
    Z009 = 9,
    Z010 = 10,
    Z011 = 11,
    Z012 = 12,
    Z013 = 13,
    Z014 = 14,
    Z015 = 15,
    Z016 = 16,
    Z017 = 17,
    Z018 = 18,
    Z019 = 19,
    Z020 = 20,
    Z021 = 21,
    Z022 = 22,
    Z023 = 23,
    Z024 = 24,
    Z025 = 25,
    Z026 = 26,
    Z027 = 27,
    Z028 = 28,
    Z029 = 29,
    Z030 = 30,
    Z031 = 31,
    Z032 = 32,
    Z033 = 33,

    pub fn parse(name: []const u8) ?Rule {
        return std.meta.stringToEnum(Rule, name);
    }
};

/// Explicit rule selection. Only the two inspected inherited core rules default on.
pub const Config = struct {
    enabled: [34]bool = core,
    max_line_length: u32 = 120,
    strict_suppressions: bool = false,
    fact_budget: usize = 100_000,

    const core = blk: {
        var selection: [34]bool = @splat(false);
        selection[3] = true;
        selection[13] = true;
        break :blk selection;
    };

    /// An empty selection for callers migrating explicit policy.
    pub fn none() Config {
        return .{ .enabled = @splat(false) };
    }
    /// The predecessor's selection, explicitly requested; Z033 remains disabled.
    pub fn compatibility() Config {
        var config = none();
        for (std.meta.tags(Rule)) |rule| config.set(rule, rule != .Z033);
        return config;
    }
    /// Selects a stable rule ID.
    pub fn set(self: *Config, rule: Rule, enabled: bool) void {
        self.enabled[@backingInt(rule)] = enabled;
    }
    /// Whether a rule was selected.
    pub fn has(self: Config, rule: Rule) bool {
        return self.enabled[@backingInt(rule)];
    }
};

test "inventory preserves exactly 32 IDs without Z008" {
    try std.testing.expectEqual(@as(usize, 32), std.meta.tags(Rule).len);
    try std.testing.expect(Rule.parse("Z008") == null);
    try std.testing.expect(Rule.parse("Z013-extra") == null);
    try std.testing.expect(!Config.compatibility().has(.Z033));
    try std.testing.expect(!@as(Config, .{}).has(.Z011));
}
