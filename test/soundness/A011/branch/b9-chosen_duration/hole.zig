// A011: std's Duration chosen by an if, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(first: bool, a: std.Io.Duration, b: std.Io.Duration) i96 {
    return (if (first) a else b).nanoseconds;
}
