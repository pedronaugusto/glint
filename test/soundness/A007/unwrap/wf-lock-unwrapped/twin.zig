// warp-fast: an optional pointer to a lock, unwrapped into a borrow.
const std = @import("std");
pub fn f(p: ?*std.Io.Mutex) void {
    const lock = p orelse return;
    _ = lock;
}
