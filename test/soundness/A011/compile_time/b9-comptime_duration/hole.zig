// A011: a comptime parameter's std Duration, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
fn nanos(comptime d: std.Io.Duration) i96 {
    return d.nanoseconds;
}
pub fn f() i96 {
    return nanos(.{ .nanoseconds = 5 });
}
