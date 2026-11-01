// warp-fast: a file closed in place through closeMany of a one-element slice of its address, then again by the defer
const std = @import("std");
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    std.Io.File.closeMany(io, (&file)[0..1]);
}
