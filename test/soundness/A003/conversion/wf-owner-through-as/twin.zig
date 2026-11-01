// warp-fast: a file opened through @as and released by its defer.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = @as(std.Io.File, try dir.openFile(io, "a", .{}));
    defer file.close(io);
}
