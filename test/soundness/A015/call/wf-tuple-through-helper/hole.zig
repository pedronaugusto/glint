// warp-fast: a field of another file's type handed in a tuple to a helper that @calls a release with it: this releases another's owner
const std = @import("std");
const S = @import("before.zig").S;
fn retrying(comptime f: anytype, args: anytype) void {
    return @call(.auto, f, args);
}
pub fn drop(s: *S, io: std.Io) void {
    retrying(std.Io.File.close, .{ s.f, io });
}
