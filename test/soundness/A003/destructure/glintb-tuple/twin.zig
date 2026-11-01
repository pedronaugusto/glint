// glint-b: A003 destructure (tuple): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file, const n = .{ try dir.openFile(io, "a", .{}), @as(u32, 1) };
    _ = n;
    file.close(io);
}
