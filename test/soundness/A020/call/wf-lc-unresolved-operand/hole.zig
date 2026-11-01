// warp-fast: a reader whose type does not resolve (made from anytype) handed to a helper that passes its ReadFailed on without its err
const std = @import("std");
fn one(r: *std.Io.File.Reader) !u8 {
    return r.interface.takeByte();
}
pub fn first(h: anytype, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = h.reader(io, &buf);
    return one(&r);
}
pub fn use(f: std.Io.File, io: std.Io) !u8 {
    return first(f, io);
}
