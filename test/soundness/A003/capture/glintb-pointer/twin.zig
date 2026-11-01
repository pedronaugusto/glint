// glint-b: A003 capture (pointer): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var maybe: ?std.Io.File = try dir.openFile(io, "a", .{});
    if (maybe) |*file| file.close(io);
}
