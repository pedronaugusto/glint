// glint-b: A003 address (alias): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var file = try dir.openFile(io, "a", .{});
    const p = &file;
    p.close(io);
}
