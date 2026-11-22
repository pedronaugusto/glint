// A011: std's Duration unwrapped from an optional by .?, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: ?std.Io.Duration) i96 {
    return d.?.nanoseconds;
}
