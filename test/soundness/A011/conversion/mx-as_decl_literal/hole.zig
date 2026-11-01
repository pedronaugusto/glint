// matrix: a raw count of seconds made std's Duration by @as with a decl literal
const std = @import("std");
pub fn f(s: i64) std.Io.Duration {
    const d = @as(std.Io.Duration, .fromSeconds(s));
    return d;
}
