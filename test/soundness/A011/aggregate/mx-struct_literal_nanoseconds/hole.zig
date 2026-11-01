// matrix: std's Duration built by a struct literal from a raw count, no door called
const std = @import("std");
pub fn f(ms: i64) std.Io.Duration {
    return .{ .nanoseconds = @as(i96, ms) * 1_000_000 };
}
