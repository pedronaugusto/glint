// glint-b: A003 conversion (cast): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = @as(std.Io.File, try dir.openFile(io, "a", .{}));
    file.close(io);
}
