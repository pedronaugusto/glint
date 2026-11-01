// matrix: a raw count written into std's Duration's nanoseconds by a compound assignment
const std = @import("std");
pub fn f(ms: i64) std.Io.Duration {
    var d: std.Io.Duration = .zero;
    d.nanoseconds += @as(i96, ms) * 1_000_000;
    return d;
}
