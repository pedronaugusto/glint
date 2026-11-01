// warp-fast: closeMany of the one-element slice is the file's one release
const std = @import("std");
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    std.Io.File.closeMany(io, (&file)[0..1]);
}
