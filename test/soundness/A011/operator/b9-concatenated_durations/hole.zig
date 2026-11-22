// A011: std's Duration an element of tuples joined by ++, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(a: std.Io.Duration, b: std.Io.Duration) i96 {
    const both = .{a} ++ .{b};
    return both[1].nanoseconds;
}
