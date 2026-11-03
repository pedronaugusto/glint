// glint-b: A003 call (a handle through a method): the method lends the directory its receiver, a local, holds; the caller uses it straight (as receiver and as argument holder) and does not close it, so it must stay clean
const std = @import("std");
const Io = std.Io;
const Scratch = struct {
    dir: Io.Dir,
    fn lent(s: *Scratch) Io.Dir {
        return s.dir;
    }
};
pub fn f(dir: Io.Dir, io: Io) !void {
    var s: Scratch = .{ .dir = dir };
    try s.lent().createDirPath(io, "later");
    const one = try s.lent().openFile(io, "one", .{});
    defer one.close(io);
}
