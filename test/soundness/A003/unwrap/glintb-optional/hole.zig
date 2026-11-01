// glint-b: A003 unwrap (optional): the unsafe shape, which must flag
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const maybe: ?std.Io.File = try dir.openFile(io, "a", .{});
    const file = maybe.?;
    _ = file;
}
