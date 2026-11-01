// warp-fast: the release runs only where a comptime parameter says; called with false, it leaks.
const std = @import("std");
fn open(comptime keep_closed: bool, dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    if (keep_closed) file.close(io);
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    try open(false, dir, io);
}
