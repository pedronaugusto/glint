// A raw count copied into std's Duration by the program's own byte loop.
const std = @import("std");
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    for (std.mem.asBytes(&d), std.mem.asBytes(&ns)) |*b, s| b.* = s;
    return d;
}
