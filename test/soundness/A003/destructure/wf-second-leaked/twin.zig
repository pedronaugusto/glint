// warp-fast: both files a destructure opens are released.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const a, const b = .{ try dir.openFile(io, "a", .{}), try dir.openFile(io, "b", .{}) };
    a.close(io);
    b.close(io);
}
