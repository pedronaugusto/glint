// warp-fast: a function given the field's name as a comptime parameter releases it: an owner.
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
fn closeNamed(s: *Stored, comptime name: []const u8, io: std.Io) void {
    @field(s, name).close(io);
}
pub fn close(s: *Stored, io: std.Io) void {
    closeNamed(s, "file", io);
}
