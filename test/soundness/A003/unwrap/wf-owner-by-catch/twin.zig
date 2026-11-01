// warp-fast: a file unwrapped by catch and released by its defer.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) void {
    const file = dir.openFile(io, "a", .{}) catch return;
    defer file.close(io);
}
