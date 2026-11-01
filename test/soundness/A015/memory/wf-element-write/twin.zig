// warp-fast: an element of the array field given only what the caller lends, never released: a borrow
const std = @import("std");
const Stored = struct { files: [2]std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.files[0] = f;
}
