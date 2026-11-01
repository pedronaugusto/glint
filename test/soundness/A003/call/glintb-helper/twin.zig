// glint-b: A003 call (helper): the same shape made safe, which must stay clean
const std = @import("std");
fn shut(file: std.Io.File, io: std.Io) void {
    file.close(io);
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    shut(try dir.openFile(io, "a", .{}), io);
}
