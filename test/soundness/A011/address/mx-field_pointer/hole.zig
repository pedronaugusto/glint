// matrix: a raw count stored through a pointer to std's Duration's nanoseconds
const std = @import("std");
pub fn f(out: *std.Io.Duration, ms: i64) void {
    const p = &out.nanoseconds;
    p.* = @as(i96, ms) * 1_000_000;
}
