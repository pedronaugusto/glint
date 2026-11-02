// A Duration copied as bytes into another Duration: no raw count.
const std = @import("std");
pub fn f(d: std.Io.Duration) std.Io.Duration {
    var e: std.Io.Duration = .zero;
    @memcpy(std.mem.asBytes(&e), std.mem.asBytes(&d));
    return e;
}
