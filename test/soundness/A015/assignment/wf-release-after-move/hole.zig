// warp-fast: the field moved into another holder's field, which is released: an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
const Other = struct { held: std.Io.File };
pub fn move(s: *Stored, o: *Other) void {
    o.held = s.file;
}
pub fn close(o: *Other, io: std.Io) void {
    o.held.close(io);
}
