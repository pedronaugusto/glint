//! Standalone compiled project rules use glint's model and CLI completion contract.
const std = @import("std");
const glint = @import("glint");
const cli = @import("glint_cli");
const local_export: glint.Rule = @fromBackingInt(1000); // safe: this example owns extension ID 1000, validated by glint.
const rules = [_]glint.ProjectRule{.{ .definition = .{ .id = local_export, .name = "LOCAL_EXPORT", .group = .family_policy, .purpose = "project public constants require an explicit export contract" }, .check = check }};
fn check(context: *glint.RuleContext) glint.RuleContext.Error!void {
    for (try context.project.declarations(try context.source())) |declaration| if (declaration.public and declaration.kind == .variable) {
        try context.at(local_export, declaration.token, "public constant requires the project's export contract");
    };
}
pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const status = cli.executeConfigured(init.gpa, init.io, args, &output.interface, &rules) catch std.process.exit(2);
    if (status != 0) std.process.exit(status);
}
