// P007: @setFloatMode given the strict mode by its full name.
const std = @import("std");
pub fn mul(a: f32, b: f32) f32 {
    @setFloatMode(std.builtin.FloatMode.strict);
    return a * b;
}
