// glint-b: A003 compile_time (known): the same shape made safe, which must stay clean
const std = @import("std");
const closing = true;
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    if (comptime closing) file.close(io);
}
