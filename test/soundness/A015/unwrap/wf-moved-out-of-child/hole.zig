// warp-fast: a pipe read out of a std.process.Child and released while the Child still names it:
// another's owner released here.
const std = @import("std");
pub fn drain(child: *std.process.Child, io: std.Io) void {
    const output = child.stderr.?;
    defer output.close(io);
}
