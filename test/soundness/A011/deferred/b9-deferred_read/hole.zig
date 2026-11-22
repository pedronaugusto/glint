// A011: std's Duration's raw nanoseconds read at the scope's end: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration, total: *i96) void {
    defer total.* += d.nanoseconds;
}
