// A raw count copied into std's Duration through the program's own byte view of it.
const std = @import("std");
fn bytes(p: *std.Io.Duration) []u8 {
    return std.mem.asBytes(p);
}
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    @memcpy(bytes(&d), std.mem.asBytes(&ns));
    return d;
}
