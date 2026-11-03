// A raw count copied into std's Duration through the program's own wrapper of std.mem.copyForwards.
const std = @import("std");
fn copy(d: []u8, s: []const u8) void {
    std.mem.copyForwards(u8, d, s);
}
pub fn f(ns: i96) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    copy(std.mem.asBytes(&d), std.mem.asBytes(&ns));
    return d;
}
