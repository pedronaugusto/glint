// warp-fast: a field of another file's type, released through @call: this releases another's owner
const std = @import("std");
const S = @import("before.zig").S;
pub fn drop(s: *S, io: std.Io) void {
    @call(.auto, std.Io.File.close, .{ s.f, io });
}
