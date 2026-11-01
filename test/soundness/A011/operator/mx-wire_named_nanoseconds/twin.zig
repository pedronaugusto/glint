// matrix: two of std's raw nanosecond counts compared: one unit, no conversion
const std = @import("std");
pub fn late(left: std.Io.Duration, limit: std.Io.Duration) bool {
    return left.nanoseconds < limit.nanoseconds;
}
