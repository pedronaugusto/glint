// warp-fast: the same reader handed to a helper that returns its err for a ReadFailed: the cause reaches the caller
const std = @import("std");
fn one(r: *std.Io.File.Reader) !u8 {
    return r.interface.takeByte() catch |e| switch (e) {
        error.ReadFailed => return r.err.?,
        else => |other| return other,
    };
}
pub fn first(h: anytype, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = h.reader(io, &buf);
    return one(&r);
}
pub fn use(f: std.Io.File, io: std.Io) !u8 {
    return first(f, io);
}
