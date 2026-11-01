// warp-fast: a copy lent to a function that only reads it; the local is released by its defer.
const std = @import("std");
fn size(f: std.Io.File, io: std.Io) !u64 {
    return (try f.stat(io)).size;
}
pub fn g(dir: std.Io.Dir, io: std.Io) !u64 {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    return size(file, io);
}
