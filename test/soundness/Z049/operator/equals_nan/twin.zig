// Z049 twin: the same done the way the rule leaves
const std = @import("std");
pub fn missing(x: f64) bool {
    return std.math.isNan(x);
}
