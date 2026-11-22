// A011: std's Duration named by a destructure, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration, n: u8) i96 {
    const held, const other = .{ d, n };
    _ = other;
    return held.nanoseconds;
}
