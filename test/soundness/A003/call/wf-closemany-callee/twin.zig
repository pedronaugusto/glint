// warp-fast: the callee only reads its copy; the defer closes the file once
const std = @import("std");
fn size(f: std.Io.File, io: std.Io) !u64 {
    return (try f.stat(io)).size;
}
pub fn g(dir: std.Io.Dir, io: std.Io) !u64 {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    return size(file, io);
}
