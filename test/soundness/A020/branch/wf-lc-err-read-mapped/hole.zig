// warp-fast: a handler reads r.err but maps every failure to another error: the cancel is still lost
const std = @import("std");
pub fn first(f: std.Io.File, io: std.Io) error{Gone}!u8 {
    var buf: [64]u8 = undefined;
    var r = f.reader(io, &buf);
    return r.interface.takeByte() catch {
        if (r.err) |e| std.log.err("read: {t}", .{e});
        return error.Gone;
    };
}
