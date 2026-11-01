// warp-fast: a break leaves the loop between the open and the close: that pass leaks.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, names: []const []const u8) !void {
    for (names) |name| {
        const file = try dir.openFile(io, name, .{});
        if (name.len == 0) break;
        file.close(io);
    }
}
