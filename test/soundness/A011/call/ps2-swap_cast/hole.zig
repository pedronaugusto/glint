// std.mem.swap through a pointer cast: a raw count goes into std's Duration and its count comes out raw.
const std = @import("std");
pub fn f(d: *std.Io.Duration, ns: *i96) void {
    std.mem.swap(i96, @ptrCast(d), ns);
}
