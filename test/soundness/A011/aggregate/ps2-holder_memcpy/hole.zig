// A raw count copied as bytes into a record that holds std's Duration by value: the Duration is written raw.
const std = @import("std");
const Timer = struct { limit: std.Io.Duration };
pub fn f(ns: i96) Timer {
    var t: Timer = .{ .limit = .zero };
    @memcpy(std.mem.asBytes(&t), std.mem.asBytes(&ns));
    return t;
}
