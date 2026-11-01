// matrix: std's door the result of a labeled block, then called with a raw count
const std = @import("std");
pub fn f(ms: i64, seconds: bool) std.Io.Duration {
    const door: *const fn (i64) std.Io.Duration = blk: {
        if (seconds) break :blk &std.Io.Duration.fromSeconds;
        break :blk &std.Io.Duration.fromMilliseconds;
    };
    return door(ms);
}
