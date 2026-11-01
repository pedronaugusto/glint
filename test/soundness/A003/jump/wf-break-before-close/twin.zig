// warp-fast: a defer in the pass releases the file before the break leaves.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, names: []const []const u8) !void {
    for (names) |name| {
        const file = try dir.openFile(io, name, .{});
        defer file.close(io);
        if (name.len == 0) break;
    }
}
