// A011: std's Duration reached through a pointer to it, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    const at = &d;
    return at.nanoseconds;
}
