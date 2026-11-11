// a003: a local set by two acquisitions, closed once: the first leaks.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var file: std.Io.File = undefined;
    file = try dir.openFile(io, "a", .{});
    file = try dir.openFile(io, "b", .{});
    file.close(io);
}
