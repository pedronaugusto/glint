// warp-fast: a callee that copies its parameter and reads only its handle releases nothing.
const std = @import("std");
fn peek(f: std.Io.File) std.Io.File.Handle {
    const g2 = f;
    return g2.handle;
}
pub fn g(dir: std.Io.Dir, io: std.Io) !void {
    const file = try dir.openFile(io, "a", .{});
    defer file.close(io);
    _ = peek(file);
}
