// warp-fast: an opened file unwrapped by catch into the field is an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, dir: std.Io.Dir, io: std.Io) void {
    s.file = dir.openFile(io, "a", .{}) catch return;
}
