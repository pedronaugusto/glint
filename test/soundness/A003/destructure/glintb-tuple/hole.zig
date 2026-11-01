// glint-b: A003 destructure (tuple): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file, const n = .{ try dir.openFile(io, "a", .{}), @as(u32, 1) };
    _ = .{ file, n };
}
