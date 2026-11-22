// P007: @setFloatMode given .optimized through a const: float results no build checks.
const std = @import("std");
const mode = std.builtin.FloatMode.optimized;
pub fn mul(a: f32, b: f32) f32 {
    @setFloatMode(mode);
    return a * b;
}
