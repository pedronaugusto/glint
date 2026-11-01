// matrix: std's raw nanoseconds narrowed to an integer by @intCast
const std = @import("std");
pub fn f(d: std.Io.Duration) u64 {
    return @intCast(d.nanoseconds);
}
