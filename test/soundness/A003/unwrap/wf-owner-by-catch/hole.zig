// warp-fast: a file unwrapped by catch is never released.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) void {
    const file = dir.openFile(io, "a", .{}) catch return;
    _ = file.handle;
}
