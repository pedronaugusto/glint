// glint-b: a callee that passes on a call's error with `try`: that exit fails wherever the call can
const std = @import("std");
fn inner(d: usize) !usize {
    if (d == 3) return error.Three;
    return d;
}
fn outer(d: usize) !usize {
    if (d == 0) return error.Zero;
    return (try inner(d)) + 1;
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
