// glint-b: A003 capture (value): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const maybe: ?std.Io.File = try dir.openFile(io, "a", .{});
    if (maybe) |file| _ = file;
}
