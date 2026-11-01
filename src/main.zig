//! Standalone CLI: complete success, selected findings, or tool/input failure.
const std = @import("std");
const cli = @import("glint").cli;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(2);
    var buffer: [8192]u8 = undefined;
    // aegis: design(A019): read only below what it wrote; ensign's Page calls it through a function-pointer field that std's generic reflective writers may store into until glint reaches them per instantiation
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var error_buffer: [4096]u8 = undefined;
    // aegis: design(A019): read only below what it wrote; ensign's Page calls it through a function-pointer field that std's generic reflective writers may store into until glint reaches them per instantiation
    var errors = std.Io.File.stderr().writer(init.io, &error_buffer);
    const status = cli.execute(init.gpa, init.io, args, &output.interface, &errors.interface) catch |err| switch (err) {
        // A write that failed has its cause on its file's writer: a cancel in either ends main as one.
        error.WriteFailed => {
            if (output.err) |cause| if (cause == error.Canceled) return error.Canceled;
            if (errors.err) |cause| if (cause == error.Canceled) return error.Canceled;
            std.process.exit(2);
        },
        else => {
            // A refused line has its message written already.
            if (err != error.InvalidArguments) try failure(&errors, err);
            std.process.exit(2);
        },
    };
    if (status != 0) std.process.exit(status);
}

/// Reports a failure on `errors`; a write that fails gives the file's own error, a cancel among it.
fn failure(errors: *std.Io.File.Writer, err: anyerror) (std.Io.File.Writer.Error || error{WriteFailed})!void {
    errors.interface.print("glint: input/tool failure: {s}\n", .{@errorName(err)}) catch return errors.err orelse error.WriteFailed;
    errors.interface.flush() catch return errors.err orelse error.WriteFailed;
}
