// warp-fast: the reader itself handed to a helper that passes its ReadFailed on, and the caller passes it on
const std = @import("std");
fn one(r: *std.Io.File.Reader) !u8 {
    return try r.interface.takeByte();
}
pub fn first(f: std.Io.File, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    return try one(&r);
}
