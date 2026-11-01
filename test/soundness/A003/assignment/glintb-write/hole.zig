// glint-b: A003 assignment (write): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var file: std.Io.File = undefined;
    file = try dir.openFile(io, "a", .{});
}
