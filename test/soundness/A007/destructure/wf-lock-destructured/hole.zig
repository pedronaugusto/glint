// warp-fast: a destructure gives a local a lock by value, copied from the one a pointer lends.
const std = @import("std");
pub fn f(p: *std.Io.Mutex) u32 {
    var lock, const n = .{ p.*, @as(u32, 1) };
    _ = &lock;
    return n;
}
