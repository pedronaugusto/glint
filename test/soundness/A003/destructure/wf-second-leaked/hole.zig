// warp-fast: two files opened into a destructure; the second is never released.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const a, const b = .{ try dir.openFile(io, "a", .{}), try dir.openFile(io, "b", .{}) };
    a.close(io);
    _ = b.handle;
}
