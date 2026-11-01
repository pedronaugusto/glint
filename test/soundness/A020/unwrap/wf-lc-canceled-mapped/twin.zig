// warp-fast: the switch on r.err.? gives Canceled back as itself
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) error{ Gone, Canceled, EndOfStream }!u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    return r.interface.takeByte() catch |e| switch (e) {
        error.ReadFailed => switch (r.err.?) {
            error.Canceled => error.Canceled,
            else => error.Gone,
        },
        error.EndOfStream => error.EndOfStream,
    };
}
