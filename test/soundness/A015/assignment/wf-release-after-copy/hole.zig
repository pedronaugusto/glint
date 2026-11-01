// warp-fast: the field copied into a variable by `=` and released there is an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, io: std.Io) void {
    var copy: std.Io.File = undefined;
    copy = s.file;
    copy.close(io);
}
