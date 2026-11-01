// warp-fast: a struct literal giving the field only a parameter, never released: a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.* = .{ .file = f, .n = 0 };
}
