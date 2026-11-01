// warp-fast: a field written through a |*p| capture with a parameter, never released: a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(maybe: ?*Stored, f: std.Io.File) void {
    if (maybe) |p| p.file = f;
}
