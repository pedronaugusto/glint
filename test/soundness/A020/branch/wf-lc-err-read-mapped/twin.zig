// warp-fast: a guard returns the cause when it is a cancel before the rest is mapped
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) error{ Canceled, Gone }!u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    return r.interface.takeByte() catch {
        if (r.err) |e| {
            if (e == error.Canceled) return error.Canceled;
            std.log.err("read: {t}", .{e});
        }
        return error.Gone;
    };
}
