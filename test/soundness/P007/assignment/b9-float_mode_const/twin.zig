// P007: @setFloatMode given .strict through a const: Zig checks float results as written.
const std = @import("std");
const mode = std.builtin.FloatMode.strict;
pub fn mul(a: f32, b: f32) f32 {
    @setFloatMode(mode);
    return a * b;
}
