// warp-fast: the field chosen as a catch's fallback and released is an owner held by hand.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, other: anyerror!std.Io.File, io: std.Io) void {
    const chosen = other catch s.file;
    chosen.close(io);
}
