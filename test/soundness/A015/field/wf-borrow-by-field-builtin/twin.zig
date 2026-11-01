// warp-fast: a field @field writes with a parameter, never released, is a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    @field(s, "file") = f;
}
