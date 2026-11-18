//! Standalone compiled project rules use glint's model and CLI completion contract.
//! A project's file states an exception to its own rule as to any other: a suppression naming
//! LOCAL_EXPORT and its reason, on the constant's line or the line before (README, Usage).
const std = @import("std");
const glint = @import("glint");
const cli = glint.cli;
const local_export: glint.Rule = @fromBackingInt(1000); // safe: this example owns extension ID 1000, validated by glint.
const rules = [_]glint.ProjectRule{.{ .definition = .{ .id = local_export, .name = "LOCAL_EXPORT", .group = .family_policy, .purpose = "project public constants require an explicit export contract" }, .check = check }};
fn check(context: *glint.RuleContext) glint.RuleContext.Error!void {
    for (try context.project.declarations(try context.source())) |declaration| if (declaration.public and declaration.kind == .variable) {
        try context.at(local_export, declaration.token, "public constant requires the project's export contract");
    };
}
pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    var problems_buffer: [1024]u8 = undefined;
    var problems = std.Io.File.stderr().writerStreaming(init.io, &problems_buffer);
    const status = cli.execute(init.gpa, init.io, args, &output.interface, &problems.interface, .{ .project_rules = &rules }) catch |err| switch (err) {
        // A write that failed has its cause on its file's writer: a cancel in either ends main as one.
        error.WriteFailed => {
            if (output.err) |cause| if (cause == error.Canceled) return error.Canceled;
            if (problems.err) |cause| if (cause == error.Canceled) return error.Canceled;
            std.process.exit(2);
        },
        else => std.process.exit(2),
    };
    if (status != 0) std.process.exit(status);
}
