// warp-fast: a local File.Reader read through a constant alias of its interface, ReadFailed passed on without r.err
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    const in = &r.interface;
    return try in.takeByte();
}
