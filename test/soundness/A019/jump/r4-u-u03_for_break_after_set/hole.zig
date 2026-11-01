// review 4: u/u03_for_break_after_set.zig
// A019: a `for` that sets each element first, then may `break`: later elements stay undefined.
pub fn f(stop: bool) u8 {
    var buf: [4]u8 = undefined;
    for (&buf) |*b| {
        b.* = 0;
        if (stop) break;
    }
    return buf[3];
}
