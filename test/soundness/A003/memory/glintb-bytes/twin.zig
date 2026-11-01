// glint-b: A003 memory (bytes): the same shape made safe, which must stay clean
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    var copy: std.Io.File = undefined;
    @memcpy(std.mem.asBytes(&copy), std.mem.asBytes(&file));
    file.close(io);
}
