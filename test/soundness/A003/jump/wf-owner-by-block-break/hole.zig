// warp-fast: a file a labeled block's break gives the local is never released.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    const file = blk: {
        break :blk try dir.openFile(io, "a", .{});
    };
    _ = file.handle;
}
