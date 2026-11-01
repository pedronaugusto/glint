// matrix: a raw count crossing into std's Duration in a defer, at the scope's exit
const std = @import("std");
pub fn f(out: *std.Io.Duration, ms: i64) void {
    defer out.* = std.Io.Duration.fromMilliseconds(ms);
}
