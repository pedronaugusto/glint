// matrix: a raw default count made std's Duration by a decl literal on orelse's right
const std = @import("std");
pub fn f(left: ?std.Io.Duration, default_ms: i64) std.Io.Duration {
    return left orelse .fromMilliseconds(default_ms);
}
