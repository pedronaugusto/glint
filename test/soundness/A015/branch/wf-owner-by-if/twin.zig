// warp-fast: an if expression choosing between two parameters gives the field a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, a: std.Io.File, b: std.Io.File, first: bool) void {
    s.file = if (first) a else b;
}
