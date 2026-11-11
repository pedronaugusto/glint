// a003: a literal of two acquisitions, only the first closed: the second leaks.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const pair = .{ try dir.openFile(io, "a", .{}), try dir.openFile(io, "b", .{}) };
    pair[0].close(io);
}
