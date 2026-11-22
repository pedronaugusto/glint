// A011: std's Duration captured from an optional, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: ?std.Io.Duration) i96 {
    if (d) |held| return held.nanoseconds;
    return 0;
}
