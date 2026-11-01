// warp-fast: a callee closes its copy through closeMany((&f)[0..1]), then the caller's defer closes it again
const std = @import("std");
fn shut(f: std.Io.File, io: std.Io) void {
    std.Io.File.closeMany(io, (&f)[0..1]);
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    shut(file, io);
}
