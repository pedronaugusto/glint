// glint-b: a callee that returns a caught error (`catch |e| return e`)
const std = @import("std");
fn inner(d: usize) !usize {
    if (d == 3) return error.Three;
    return d;
}
fn outer(d: usize) !usize {
    if (d == 0) return error.Zero;
    const x = inner(d) catch |e| return e;
    return x;
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
