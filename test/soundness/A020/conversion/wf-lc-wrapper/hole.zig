// warp-fast: a limited reader made over a local File.Reader's interface: its ReadFailed is the File.Reader's, passed on
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    var lbuf: [16]u8 = undefined;
    var lim = r.interface.limited(.limited(10), &lbuf);
    return try lim.interface.takeByte();
}
