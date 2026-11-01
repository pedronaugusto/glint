// matrix: std's doors taken out of a tuple by a destructure, then called with a raw count
const std = @import("std");
pub fn f(ms: i64) i64 {
    const from, const to = .{ std.Io.Duration.fromMilliseconds, std.Io.Duration.toSeconds };
    return to(from(ms));
}
