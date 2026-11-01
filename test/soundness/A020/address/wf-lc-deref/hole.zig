// warp-fast: a pointer to the local reader read by p.*.interface, ReadFailed passed on
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    const p = &r;
    return try p.*.interface.takeByte();
}
