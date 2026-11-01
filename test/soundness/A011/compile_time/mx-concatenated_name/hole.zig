// matrix: std's ns_per_ms reached by @field with a name the compiler concatenates
const std = @import("std");
pub fn f(ms: u64) u64 {
    return ms * @field(std.time, "ns_per_" ++ "ms");
}
