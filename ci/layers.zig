//! Source layers, lowest first; tests are outside the production graph.
const gantry = @import("gantry");
pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "front end and selection", .patterns = &.{ "src/File.zig", "src/Rule.zig", "src/names.zig", "src/Completion.zig" } },
    .{ .name = "bindings and comments", .patterns = &.{ "src/Model.zig", "src/Suppression.zig" } },
    .{ .name = "project", .patterns = &.{"src/Project.zig"} },
    .{ .name = "facts and diagnostics", .patterns = &.{ "src/Facts.zig", "src/Report.zig" } },
    .{ .name = "projection and usage", .patterns = &.{ "src/Projection.zig", "src/Usage.zig" } },
    .{ .name = "rule API", .patterns = &.{"src/RuleContext.zig"} },
    .{ .name = "built-in rules", .patterns = &.{ "src/Builtins.zig", "src/DeadDeclarations.zig" } },
    .{ .name = "rules", .patterns = &.{"src/Runner.zig"} },
    .{ .name = "public", .patterns = &.{"src/glint.zig"} },
    .{ .name = "filesystem CLI", .patterns = &.{ "src/cli.zig", "src/Result.zig" } },
    .{ .name = "entry", .patterns = &.{"src/main.zig"} },
};
pub const required = [_][]const u8{ "src/glint.zig", "src/Project.zig", "src/main.zig" };
pub const entries: []const []const u8 = &.{"src/main.zig"};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{ "std", "builtin", "glint", "shakedown", "aegis" } },
};

pub const modules: []const gantry.NamedModule = &.{};
pub const owned: []const gantry.rules.TokenRule = &.{};
