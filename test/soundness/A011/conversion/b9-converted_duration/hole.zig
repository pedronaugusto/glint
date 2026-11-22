// A011: std's Duration converted by @as, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    return @as(std.Io.Duration, d).nanoseconds;
}
