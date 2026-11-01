// warp-fast: a local an if expression gives an opened file on one arm and stdout on the other may
// own a file: never cleared.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, fresh: bool) !void {
    const file = if (fresh) try dir.openFile(io, "a", .{}) else std.Io.File.stdout();
    _ = file.handle;
}
