// warp-fast: seekBy's ReadFailed returns the reader's cause
const std = @import("std");
pub fn skip(f: std.Io.File, io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var r = f.readerStreaming(io, &buf);
    r.seekBy(100) catch |e| switch (e) {
        error.ReadFailed => return r.err.?,
        else => |other| return other,
    };
}
