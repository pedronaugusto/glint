// matrix: std's Duration read out raw in a function taking it as anytype
const std = @import("std");
fn millis(d: anytype) i64 {
    return d.toMilliseconds();
}
pub fn f(d: std.Io.Duration) i64 {
    return millis(d);
}
