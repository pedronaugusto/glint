// warp-fast: a file opened through @as is never released.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = @as(std.Io.File, try dir.openFile(io, "a", .{}));
    _ = file.handle;
}
