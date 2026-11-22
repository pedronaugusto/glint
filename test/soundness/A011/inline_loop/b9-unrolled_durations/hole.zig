// A011: std's Durations an unrolled loop's capture, each one's raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(a: std.Io.Duration, b: std.Io.Duration) i96 {
    var total: i96 = 0;
    inline for (.{ a, b }) |held| total += held.nanoseconds;
    return total;
}
