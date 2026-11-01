// warp-fast: an optional lock behind a pointer, unwrapped into a local by value.
const std = @import("std");
pub fn f(p: *const ?std.Io.Mutex) void {
    var lock = p.*.?;
    _ = &lock;
}
