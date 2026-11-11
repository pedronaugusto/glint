// Z049: the reported form
const std = @import("std");
pub fn missing(x: f64) bool {
    return x == std.math.nan(f64);
}
