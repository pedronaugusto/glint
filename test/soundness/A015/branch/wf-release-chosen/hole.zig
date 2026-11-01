// warp-fast: the field chosen by an if expression and released is an owner held by hand.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, other: std.Io.File, first: bool, io: std.Io) void {
    const chosen = if (first) s.file else other;
    chosen.close(io);
}
