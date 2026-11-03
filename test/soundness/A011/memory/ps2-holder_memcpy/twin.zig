// The record's Duration made through std's own constructor.
const std = @import("std");
const Timer = struct { limit: std.Io.Duration };
pub fn f(other: Timer) Timer {
    var t: Timer = .{ .limit = .zero };
    @memcpy(std.mem.asBytes(&t), std.mem.asBytes(&other));
    return t;
}
