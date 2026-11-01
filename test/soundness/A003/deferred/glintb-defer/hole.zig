// glint-b: A003 deferred (defer): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, c: bool) !void {
    const file = try dir.openFile(io, "a", .{});
    defer if (c) file.close(io);
}
