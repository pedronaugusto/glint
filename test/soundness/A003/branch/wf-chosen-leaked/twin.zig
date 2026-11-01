// warp-fast: the file the if expression opens is released by its defer.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, fresh: bool) !void {
    const file = if (fresh) try dir.createFile(io, "a", .{}) else try dir.openFile(io, "a", .{});
    defer file.close(io);
}
