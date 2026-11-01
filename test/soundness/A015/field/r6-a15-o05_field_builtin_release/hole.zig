// review 6: a15/o05_field_builtin_release.zig
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
// Given only a parameter (a borrow by its writes), but released through @field: an owner.
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn close(s: *Stored, io: std.Io) void {
    @field(s, "file").close(io);
}
