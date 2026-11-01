// warp-fast: a file an if expression opens one of two ways is never released.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, fresh: bool) !void {
    const file = if (fresh) try dir.createFile(io, "a", .{}) else try dir.openFile(io, "a", .{});
    _ = file.handle;
}
