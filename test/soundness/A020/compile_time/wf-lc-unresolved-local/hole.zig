// warp-fast: a generic function makes its own reader from an anytype: a local whose type does not resolve, read through its interface and passed on, is undecided
const std = @import("std");
pub fn first(h: anytype, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = h.reader(io, &buf);
    return try r.interface.takeByte();
}
