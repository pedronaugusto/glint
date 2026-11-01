// warp-fast: the payload is released in the branch that captures it.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) void {
    if (dir.openFile(io, "a", .{})) |file| {
        file.close(io);
    } else |_| {}
}
