// warp-fast: the helper given the reader returns its cause on ReadFailed itself
const std = @import("std");
fn one(r: *std.Io.File.Reader) !u8 {
    return r.interface.takeByte() catch |e| switch (e) {
        error.ReadFailed => r.err.?,
        else => |other| other,
    };
}
pub fn first(f: std.Io.File, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    return try one(&r);
}
