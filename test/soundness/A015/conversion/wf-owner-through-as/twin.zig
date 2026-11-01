// warp-fast: a parameter given the field through @as is a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = @as(std.Io.File, f);
}
