// warp-fast: each unrolled pass releases the file it opens.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    inline for (.{ "a", "b" }) |name| {
        const file = try dir.openFile(io, name, .{});
        defer file.close(io);
    }
}
