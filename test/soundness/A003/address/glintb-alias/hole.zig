// glint-b: A003 address (alias): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    var file = try dir.openFile(io, "a", .{});
    const p = &file;
    _ = p;
}
