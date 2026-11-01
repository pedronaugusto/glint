// review 4: u/u08_error_set_return.zig
// A019: a function returning an error set as a value (not an error union): `return error.X` is an
// ordinary return, not a failure the caller's try leaves by.
fn fill(p: *[4]u8, c: bool) anyerror {
    if (c) return error.Skipped;
    p.* = .{ 1, 2, 3, 4 };
    return error.Done;
}
pub fn main(c: bool) u8 {
    var buf: [4]u8 = undefined;
    if (fill(&buf, c) == error.Never) return 0;
    return buf[3];
}
