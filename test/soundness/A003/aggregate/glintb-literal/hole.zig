// glint-b: A003 aggregate (literal): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const pair = .{ try dir.openFile(io, "a", .{}), @as(u32, 1) };
    _ = pair;
}
