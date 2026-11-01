// glint-b: A003 field (named): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    @field(std.Io.File, "close")(file, io);
}
