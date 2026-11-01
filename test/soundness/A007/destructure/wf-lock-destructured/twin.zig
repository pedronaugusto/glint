// warp-fast: a destructure gives a local the pointer the caller lends: a borrow.
const std = @import("std");
pub fn f(p: *std.Io.Mutex) u32 {
    const lock, const n = .{ p, @as(u32, 1) };
    _ = lock;
    return n;
}
