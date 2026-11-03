// glint-b: A003 call (a handle through a method): the method opens a new directory, which the caller, holding the receiver in a local, never closes, so it must flag
const std = @import("std");
const Io = std.Io;
const Scratch = struct {
    dir: Io.Dir,
    fn sub(s: *Scratch, io: Io) !Io.Dir {
        return s.dir.openDir(io, "sub", .{});
    }
};
pub fn f(dir: Io.Dir, io: Io) !void {
    var s: Scratch = .{ .dir = dir };
    const sub = try s.sub(io);
    try sub.createDirPath(io, "later");
}
