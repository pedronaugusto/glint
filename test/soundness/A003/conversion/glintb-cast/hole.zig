// glint-b: A003 conversion (cast): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = @as(std.Io.File, try dir.openFile(io, "a", .{}));
    _ = file;
}
