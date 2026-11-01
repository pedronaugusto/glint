// warp-fast: a for capture by value copies each lock the slice lends.
const std = @import("std");
pub fn f(locks: []const std.Io.Mutex) usize {
    var n: usize = 0;
    for (locks) |lock| {
        _ = lock;
        n += 1;
    }
    return n;
}
