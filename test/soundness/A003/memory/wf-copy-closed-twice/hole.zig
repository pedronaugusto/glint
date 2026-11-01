// warp-fast: a copy made by @memcpy and the original are both released: a double close.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    var copy: std.Io.File = undefined;
    @memcpy(std.mem.asBytes(&copy), std.mem.asBytes(&file));
    copy.close(io);
    file.close(io);
}
