//! A configuration document read (the `--config` file and a repository's glint.json): its
//! profile and code options, and its rule settings by name, which `cli.resolve` checks against
//! the run's rules. The bytes are untrusted; a document is refused whole for its JSON.
const std = @import("std");
const Rule = @import("Rule.zig");

/// Strict JSON policy, containing code options only. Callers own file selection.
pub const Configuration = struct {
    /// `core`, `none` or `reviewed`; any other is refused.
    profile: []const u8 = "core",
    rules: []const Setting = &.{},
    max_line_length: u32 = 100,
    max_function_lines: u32 = 120,
    max_parameters: u32 = 7,
    max_nesting: u32 = 5,
    max_stack_array: u64 = 64 * 1024,
    function_exceptions: []const Rule.Config.FunctionException = &.{},
    disallowed: []const Rule.Config.Disallowed = &.{},
    strict_suppressions: bool = false,
    metrics: bool = false,
    fact_budget: usize = 100_000,
    seams: []const Rule.Config.Seam = &.{},
    test_inputs: []const Rule.Config.TestInput = &.{},
    pub const Setting = struct { id: []const u8, level: Rule.Config.Level };
};

pub const ConfigureError = std.json.ParseError(std.json.Scanner) || error{InvalidSelection};
pub const Configured = struct { config: Rule.Config, package_defaults: bool, settings: []const Configuration.Setting, refused_profile: ?[]const u8 = null };
/// A configuration's profile and code options; its rule settings are named, for `resolve`.
pub fn configure(a: std.mem.Allocator, bytes: []const u8) ConfigureError!Configured {
    const document = try std.json.parseFromSliceLeaky(Configuration, a, bytes, .{});
    const profile = std.meta.stringToEnum(enum { core, none, reviewed }, document.profile) orelse
        return .{ .config = .{}, .package_defaults = false, .settings = &.{}, .refused_profile = document.profile };
    var config: Rule.Config = switch (profile) {
        .core => .{},
        .none => Rule.Config.none(),
        .reviewed => Rule.Config.reviewed(),
    };
    config.max_line_length = document.max_line_length;
    config.max_function_lines = document.max_function_lines;
    config.max_parameters = document.max_parameters;
    config.max_nesting = document.max_nesting;
    config.max_stack_array = document.max_stack_array;
    config.function_exceptions = document.function_exceptions;
    config.disallowed = document.disallowed;
    config.strict_suppressions = document.strict_suppressions;
    config.metrics = document.metrics;
    config.fact_budget = document.fact_budget;
    config.seams = document.seams;
    config.test_inputs = document.test_inputs;
    try config.validate();
    return .{ .config = config, .package_defaults = profile != .none, .settings = document.rules };
}
