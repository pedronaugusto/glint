// review 4: u/u03b_for_break_after_set_safe_shape.zig
// baseline: a `for` that sets each element with no way out (expected clean)
pub fn f() u8 {
    var buf: [4]u8 = undefined;
    for (&buf) |*b| {
        b.* = 0;
    }
    return buf[3];
}
