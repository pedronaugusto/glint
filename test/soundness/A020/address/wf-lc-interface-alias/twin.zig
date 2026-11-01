// warp-fast: the alias's ReadFailed returns r.err, error.Canceled among it
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) !u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    const in = &r.interface;
    return in.takeByte() catch |e| switch (e) {
        error.ReadFailed => return r.err.?,
        error.EndOfStream => return error.EndOfStream,
    };
}
