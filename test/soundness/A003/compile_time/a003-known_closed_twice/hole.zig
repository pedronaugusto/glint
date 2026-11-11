// a003: closed under a branch known to be taken, then again: a double close.
const std = @import("std");
const closing = true;
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    if (comptime closing) file.close(io);
    file.close(io);
}
