// glint-b: A003 call (helper): the unsafe shape, which must flag
const std = @import("std");
fn keep(file: std.Io.File) void {
    _ = file;
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    keep(try dir.openFile(io, "a", .{}));
}
