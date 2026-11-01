// warp-fast: a local copies by value the lock a pointer lends.
const std = @import("std");
pub fn f(p: *std.Io.Mutex) void {
    var copy = p.*;
    _ = &copy;
}
