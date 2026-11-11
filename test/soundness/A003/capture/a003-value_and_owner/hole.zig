// a003: closed through a value capture, then through the optional itself: a double close.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const maybe: ?std.Io.File = try dir.openFile(io, "a", .{});
    if (maybe) |file| {
        file.close(io);
        maybe.?.close(io);
    }
}
