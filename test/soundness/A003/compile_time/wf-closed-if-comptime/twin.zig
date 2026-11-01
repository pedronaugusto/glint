// warp-fast: a comptime parameter chooses what is read, never whether the file is released.
const std = @import("std");
fn open(comptime with_size: bool, dir: std.Io.Dir, io: std.Io) !u64 {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    return if (with_size) (try file.stat(io)).size else 0;
}
pub fn f(dir: std.Io.Dir, io: std.Io) !u64 {
    return open(false, dir, io);
}
