// glint-b: A003 assignment (write): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var file: std.Io.File = undefined;
    file = try dir.openFile(io, "a", .{});
    file.close(io);
}
