// a003: the payload copied by `.?` closed, then the optional's payload closed again: a double close.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const maybe: ?std.Io.File = try dir.openFile(io, "a", .{});
    const file = maybe.?;
    file.close(io);
    maybe.?.close(io);
}
