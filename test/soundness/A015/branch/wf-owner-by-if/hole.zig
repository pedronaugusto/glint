// warp-fast: an if expression choosing between two opened files gives the field an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io, fresh: bool) !void {
    s.file = if (fresh) try dir.createFile(io, "a", .{}) else try dir.openFile(io, "a", .{});
}
