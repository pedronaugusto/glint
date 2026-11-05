// glint-b: a callee that answers a call's error itself (`catch 0`): it fails only where its divisor is zero
const std = @import("std");
fn inner(d: usize) !usize {
    if (d == 3) return error.Three;
    return d;
}
fn outer(d: usize) !usize {
    if (d == 0) return error.Zero;
    const x: usize = inner(d) catch 0;
    return x;
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
