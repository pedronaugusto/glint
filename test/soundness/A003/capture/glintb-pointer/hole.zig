// glint-b: A003 capture (pointer): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var maybe: ?std.Io.File = try dir.openFile(io, "a", .{});
    if (maybe) |*file| _ = file;
}
