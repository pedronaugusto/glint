// std's Duration copied out as raw bytes into an integer: a raw count read past the door.
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    var ns: i96 = 0;
    @memcpy(std.mem.asBytes(&ns), std.mem.asBytes(&d));
    return @divTrunc(ns, 1000);
}
