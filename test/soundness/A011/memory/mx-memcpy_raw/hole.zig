// matrix: a raw count copied into std's Duration's bytes by @memcpy
const std = @import("std");
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    @memcpy(std.mem.asBytes(&d), std.mem.asBytes(&ns));
    return d;
}
