// warp-fast: the field released by a defer is an owner held by hand.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn finish(s: *Stored, io: std.Io) void {
    defer s.file.close(io);
    s.n = 0;
}
