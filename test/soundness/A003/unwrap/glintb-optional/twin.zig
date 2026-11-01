// glint-b: A003 unwrap (optional): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const maybe: ?std.Io.File = try dir.openFile(io, "a", .{});
    const file = maybe.?;
    file.close(io);
}
