// warp-fast: an opened file given the field through @as is still an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) !void {
    s.file = @as(std.Io.File, try dir.openFile(io, "a", .{}));
}
