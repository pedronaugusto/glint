// warp-fast: a file an if's payload captures is never released.
const std = @import("std");
pub fn f(dir: std.Io.Dir, io: std.Io) void {
    if (dir.openFile(io, "a", .{})) |file| {
        _ = file.handle;
    } else |_| {}
}
