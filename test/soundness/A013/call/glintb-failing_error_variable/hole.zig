// glint-b: a callee that returns an error held in a variable, not written as `error.X` there
const std = @import("std");
fn outer(d: usize) !usize {
    const refused: anyerror = error.Refused;
    if (d == 0) return error.Zero;
    if (d == 3) return refused;
    return d;
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
