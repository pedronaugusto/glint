// matrix: a raw count returned as std's Duration through a decl literal, its type the function's result
const std = @import("std");
pub fn f(ms: i64) std.Io.Duration {
    return .fromMilliseconds(ms);
}
