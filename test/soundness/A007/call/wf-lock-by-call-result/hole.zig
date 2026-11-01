// warp-fast: a local holds by value the lock a call returns, its type never spelled there.
const std = @import("std");
fn make() std.Io.Mutex {
    return .init;
}
pub fn f() void {
    var lock = make();
    _ = &lock;
}
