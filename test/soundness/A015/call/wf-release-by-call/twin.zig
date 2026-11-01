// warp-fast: the same field read through @call by an operation that does not release it
const std = @import("std");
const S = @import("before.zig").S;
pub fn size(s: *S, io: std.Io) !u64 {
    const st = try @call(.auto, std.Io.File.stat, .{ s.f, io });
    return st.size;
}
