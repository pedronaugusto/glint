// glint-c: a method of an `anytype` parameter's value makes what its binding's type gives:
// this binding makes it a File that is never closed.
const std = @import("std");
const Opener = struct {
    pub fn open(_: Opener, dir: std.Io.Dir, io: std.Io) !std.Io.File {
        return dir.openFile(io, "a", .{});
    }
};
pub fn leak(opener: anytype, dir: std.Io.Dir, io: std.Io) !void {
    const file = try opener.open(dir, io);
    _ = file;
}
pub fn f(dir: std.Io.Dir, io: std.Io) !void {
    try leak(Opener{}, dir, io);
}
