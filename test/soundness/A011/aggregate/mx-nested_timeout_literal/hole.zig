// matrix: a raw count inside a Timeout literal: Clock.Duration's raw built by a decl literal
const std = @import("std");
pub fn f(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}
