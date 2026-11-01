// warp-fast: an inline for releases the field by the name it unrolls: an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, io: std.Io) void {
    inline for (.{"file"}) |name| @field(s, name).close(io);
}
