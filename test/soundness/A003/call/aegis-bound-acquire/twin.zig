// A003: the same, bound to std.Io.Dir in the program: the file opened is closed.
const std = @import("std");
pub fn touch(comptime T: type, dir: T, io: std.Io) !void {
    const f = try dir.openFile(io, "x", .{});
    f.close(io);
}
pub fn run(dir: std.Io.Dir, io: std.Io) !void {
    try touch(std.Io.Dir, dir, io);
}
