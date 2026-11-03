// warp-fast: the same tuple through the same helper to a function that only reads it
const std = @import("std");
const S = @import("before.zig").S;
fn retrying(comptime f: anytype, args: anytype) void {
    return @call(.auto, f, args);
}
fn peek(file: std.Io.File, io: std.Io) void {
    _ = file;
    _ = io;
}
pub fn look(s: *S, io: std.Io) void {
    retrying(peek, .{ s.f, io });
}
