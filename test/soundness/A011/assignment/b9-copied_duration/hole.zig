// A011: std's Duration copied into a const, its raw nanoseconds read there: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration) i96 {
    const held = d;
    return held.nanoseconds;
}
