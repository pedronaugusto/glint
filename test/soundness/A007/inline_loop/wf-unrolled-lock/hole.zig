// warp-fast: an inline for's capture is a lock type a local holds by value.
const std = @import("std");
pub fn f() void {
    inline for (.{std.Io.Mutex}) |T| {
        var lock: T = .init;
        _ = &lock;
    }
}
