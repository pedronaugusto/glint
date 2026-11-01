// warp-fast: a local File.Writer whose WriteFailed (its cause on w.err) is passed on
const std = @import("std");
pub fn put(f: std.Io.File, io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll("hello");
}
