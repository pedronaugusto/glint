// warp-fast: a parameter's bytes copied into the field by @memcpy: a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    @memcpy(std.mem.asBytes(&s.file), std.mem.asBytes(&f));
}
