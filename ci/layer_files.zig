//! The files of each of glint's source layers, lowest first: the layer table's (layers.zig), and
//! what the rule readers' guard reads (build.zig): every source of glint's own except the files of
//! the layers that hold no rules and the shared queries, so a new file is counted unless it is
//! placed in one of those. Plain data, so the build script reads it as layers.zig does.
pub const Layer = struct { name: []const u8, patterns: []const []const u8 };
pub const layers = [_]Layer{
    .{ .name = "tokens", .patterns = &.{ "src/Token.zig", "src/Token/**" } },
    .{ .name = "front end and selection", .patterns = &.{ "src/File.zig", "src/Constructs.zig", "src/Rule.zig", "src/names.zig", "src/Completion.zig" } },
    .{ .name = "bindings and comments", .patterns = &.{ "src/Model.zig", "src/Suppression.zig" } },
    .{ .name = "project", .patterns = &.{"src/Project.zig"} },
    .{ .name = "facts and diagnostics", .patterns = &.{ "src/Facts.zig", "src/PackageRules.zig", "src/Library.zig", "src/Report.zig", "src/Fix.zig" } },
    .{ .name = "rule API", .patterns = &.{"src/RuleContext.zig"} },
    .{ .name = "built-in rules", .patterns = &.{ "src/Builtins.zig", "src/Written.zig", "src/SameOperands.zig", "src/RepeatedCondition.zig", "src/NarrowWidened.zig", "src/LargeStackArray.zig", "src/FixedComparison.zig", "src/ExpectComparison.zig", "src/DiscardedCount.zig", "src/breadth.zig", "src/DeadDeclarations.zig", "src/Disallowed.zig", "src/Governed.zig", "src/Escapes.zig", "src/Metrics.zig", "src/AegisRules.zig", "src/AegisContract.zig", "src/Danger.zig", "src/DangerShapes.zig", "src/Program.zig", "src/AegisPack.zig" } },
    .{ .name = "rules", .patterns = &.{"src/Runner.zig"} },
    .{ .name = "filesystem CLI", .patterns = &.{ "src/cli.zig", "src/Result.zig" } },
    .{ .name = "public", .patterns = &.{"src/glint.zig"} },
    .{ .name = "entry", .patterns = &.{ "src/main.zig", "src/BuildGate.zig" } },
};
/// The layer the rules are in: the guard reads its files.
pub const rules_layer = "built-in rules";
/// The files of the rules' layer that are shared queries a rule reads through (`Governed`), where
/// reading syntax belongs: the guard does not read them.
pub const shared_queries = [_][]const u8{"src/Governed.zig"};
