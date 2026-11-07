// consolidate: a field its file releases by std's declaration, called by its path, holds an owner
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, io: std.Io) void {
    std.Io.File.close(s.file, io);
}
