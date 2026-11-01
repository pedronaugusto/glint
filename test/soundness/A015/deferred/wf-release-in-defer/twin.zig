// warp-fast: a defer that only clears a count releases nothing: the field is a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn finish(s: *Stored) void {
    defer s.n = 0;
    s.n += 1;
}
