// A011: std's Duration converted by hand, its member called as a method: a finding.
const aegis = @import("aegis");
const std = @import("std");
pub fn f(d: std.Io.Duration) i64 {
    return d.toMilliseconds();
}
