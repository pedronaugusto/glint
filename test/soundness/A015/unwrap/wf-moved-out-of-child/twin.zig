// warp-fast: a pipe moved out of a std.process.Child (read, then the field set to null) is this
// function's to release: the Child no longer names it (preflight's runner.zig).
const std = @import("std");
pub fn drain(child: *std.process.Child, io: std.Io) void {
    const output = child.stderr.?;
    child.stderr = null;
    defer output.close(io);
}
