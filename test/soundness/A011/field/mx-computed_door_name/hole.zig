// matrix: std's door reached by @field with a name held in a constant, never spelled at the call
const std = @import("std");
const door = "fromMilliseconds";
pub fn f(ms: i64) std.Io.Duration {
    return @field(std.Io.Duration, door)(ms);
}
