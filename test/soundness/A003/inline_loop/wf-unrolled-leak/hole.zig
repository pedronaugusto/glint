// warp-fast: each unrolled pass of an inline for opens a file it never releases.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    inline for (.{ "a", "b" }) |name| {
        const file = try dir.openFile(io, name, .{});
        _ = file.handle;
    }
}
