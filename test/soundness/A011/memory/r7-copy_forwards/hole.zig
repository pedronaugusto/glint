// A raw count copied into std's Duration's bytes by std's copyForwards, not a builtin.
const std = @import("std");
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    std.mem.copyForwards(u8, std.mem.asBytes(&d), std.mem.asBytes(&ns));
    return d;
}
