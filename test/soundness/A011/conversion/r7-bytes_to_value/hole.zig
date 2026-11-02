// A raw count made std's Duration by std.mem.bytesToValue: the bytes cross no door.
const std = @import("std");
pub fn f(ns: i96) std.Io.Duration {
    return std.mem.bytesToValue(std.Io.Duration, std.mem.asBytes(&ns));
}
