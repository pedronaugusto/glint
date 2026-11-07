//! Source layers, lowest first; tests are outside the production graph.
const gantry = @import("gantry");
const files = @import("layer_files.zig");
pub const layers: []const gantry.rules.Layer = blk: {
    var out: [files.layers.len]gantry.rules.Layer = undefined;
    for (files.layers, &out) |layer, *each| each.* = .{ .name = layer.name, .patterns = layer.patterns };
    const done = out;
    break :blk &done;
};
pub const required = [_][]const u8{ "src/glint.zig", "src/Project.zig", "src/main.zig" };
pub const entries: []const []const u8 = &.{ "src/main.zig", "src/BuildGate.zig" };
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{ "std", "builtin", "glint", "shakedown", "aegis", "aegis_sources", "release", "ensign" } },
};

pub const modules: []const gantry.NamedModule = &.{};
pub const owned: []const gantry.rules.TokenRule = &.{};
