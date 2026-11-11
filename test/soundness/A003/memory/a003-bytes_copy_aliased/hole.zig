// a003: a byte copy whose address was taken before the copy: closed through that pointer and by the original, a double close.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    var copy: std.Io.File = undefined;
    const p = &copy;
    @memcpy(std.mem.asBytes(&copy), std.mem.asBytes(&file));
    file.close(io);
    p.close(io);
}
