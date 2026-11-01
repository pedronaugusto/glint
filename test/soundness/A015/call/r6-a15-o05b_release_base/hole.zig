// review 6: a15/o05b_release_base.zig
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, io: std.Io) void {
    s.file.close(io);
}
