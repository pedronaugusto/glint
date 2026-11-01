// warp-fast: a defer releases the owner once on every exit.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    _ = try file.stat(io);
}
