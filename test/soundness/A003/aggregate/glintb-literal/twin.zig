// glint-b: A003 aggregate (literal): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const pair = .{ try dir.openFile(io, "a", .{}), @as(u32, 1) };
    pair[0].close(io);
}
