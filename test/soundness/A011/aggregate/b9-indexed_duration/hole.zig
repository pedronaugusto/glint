// A011: std's Duration an element of an array literal, its raw nanoseconds read: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(a: std.Io.Duration, b: std.Io.Duration) i96 {
    const pair = [2]std.Io.Duration{ a, b };
    return pair[1].nanoseconds;
}
