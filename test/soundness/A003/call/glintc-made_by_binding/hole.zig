// glint-c: what a generic makes through its type parameter is each binding's. `T.open` is
// named as no acquisition, yet this binding makes it a File that is never closed.
const std = @import("std");
const Files = struct {
    pub fn open(dir: std.Io.Dir, io: std.Io) !std.Io.File {
        return dir.openFile(io, "a", .{});
    }
};
pub fn leak(comptime T: type, dir: std.Io.Dir, io: std.Io) !void {
    const file = try T.open(dir, io);
    _ = file;
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    try leak(Files, dir, io);
}
