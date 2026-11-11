// a003: closed through a pointer to the local, then by the local itself: a double close.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var file = try dir.openFile(io, "a", .{});
    const p = &file;
    p.close(io);
    file.close(io);
}
