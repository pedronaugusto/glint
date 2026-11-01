// matrix: std's Duration bound by a switch prong's capture, read out as raw milliseconds
const std = @import("std");
pub fn f(t: std.Io.Timeout) i64 {
    return switch (t) {
        .duration => |d| d.raw.toMilliseconds(),
        else => 0,
    };
}
