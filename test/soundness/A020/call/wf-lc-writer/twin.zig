// warp-fast: the writer's WriteFailed returns w.err, error.Canceled among it
const std = @import("std");
pub fn put(f: std.Io.File, io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var w = f.writer(io, &buf);
    w.interface.writeAll("hello") catch return w.err.?;
}
