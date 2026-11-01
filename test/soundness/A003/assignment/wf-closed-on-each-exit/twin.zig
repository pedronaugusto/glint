// warp-fast: closed before the early return and at the end: released on every exit.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io, c: bool) !void {
    const file = try dir.openFile(io, "a", .{});
    if (c) {
        file.close(io);
        return;
    }
    file.close(io);
}
