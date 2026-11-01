// warp-fast: the wrapper's ReadFailed returns the wrapped reader's cause
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    var lbuf: [16]u8 = undefined;
    var lim = r.interface.limited(.limited(10), &lbuf);
    return lim.interface.takeByte() catch |e| switch (e) {
        error.ReadFailed => r.err.?,
        else => |other| other,
    };
}
