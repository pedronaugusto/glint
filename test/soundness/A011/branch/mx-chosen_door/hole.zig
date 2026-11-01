// matrix: std's door chosen by an if expression, then called with a raw count
const std = @import("std");
pub fn f(n: i64, seconds: bool) std.Io.Duration {
    const door: *const fn (i64) std.Io.Duration = if (seconds) &std.Io.Duration.fromSeconds else &std.Io.Duration.fromMilliseconds;
    return door(n);
}
