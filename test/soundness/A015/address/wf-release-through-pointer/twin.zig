// warp-fast: a pointer to the field read for its handle releases nothing: a borrow.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn handle(s: *Stored) std.Io.File.Handle {
    const p = &s.file;
    return p.handle;
}
