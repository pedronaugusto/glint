// matrix: std's Duration out of an optional by .?, read out as raw milliseconds
const std = @import("std");
pub fn f(left: ?std.Io.Duration) i64 {
    return left.?.toMilliseconds();
}
