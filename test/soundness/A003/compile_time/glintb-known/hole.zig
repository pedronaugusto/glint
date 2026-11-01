// glint-b: A003 compile_time (known): the unsafe shape, which must flag
const std = @import("std");
const closing = false;
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    if (comptime closing) file.close(io);
}
