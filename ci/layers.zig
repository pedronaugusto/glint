//! Source layers, lowest first; tests are outside the production graph.
const gantry = @import("gantry");
pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "sources and model", .patterns = &.{"src/Project.zig"} },
    .{ .name = "public", .patterns = &.{"src/glint.zig"} },
    .{ .name = "cli", .patterns = &.{"src/main.zig"} },
};
pub const required = [_][]const u8{ "src/glint.zig", "src/Project.zig", "src/main.zig" };
pub const entries: []const []const u8 = &.{"src/main.zig"};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{ "std", "builtin", "glint", "shakedown" } },
};

pub const modules: []const gantry.NamedModule = &.{};
pub const owned: []const gantry.rules.TokenRule = &.{};
