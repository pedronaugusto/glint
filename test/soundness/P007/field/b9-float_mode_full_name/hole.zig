// P007: @setFloatMode given the mode by its full name, std.builtin.FloatMode.optimized.
const std = @import("std");
pub fn mul(a: f32, b: f32) f32 {
    @setFloatMode(std.builtin.FloatMode.optimized);
    return a * b;
}
