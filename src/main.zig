//! Standalone CLI: complete success, selected findings, or tool/input failure.
const std = @import("std");
const cli = @import("glint").cli;

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    var buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const status = cli.execute(init.gpa, init.io, args, &output.interface) catch |err| {
        var error_buffer: [4096]u8 = undefined;
        var errors = std.Io.File.stderr().writer(init.io, &error_buffer);
        errors.interface.print("glint: input/tool failure: {s}\n", .{@errorName(err)}) catch std.process.exit(2);
        errors.interface.flush() catch std.process.exit(2);
        std.process.exit(2);
    };
    if (status != 0) std.process.exit(status);
}
