// consolidate: a std function that only shares a release's name (`posix.kill` given the
// handle) releases nothing: the field holds what it is given, a borrow
const std = @import("std");
const Stored = struct { file: std.Io.File, n: u32 };
pub fn store(s: *Stored, f: std.Io.File) void {
    s.file = f;
}
pub fn signal(s: *Stored) !void {
    try std.posix.kill(s.file.handle, .TERM);
}
