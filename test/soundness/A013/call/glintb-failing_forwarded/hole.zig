// glint-b: a callee whose error comes from the call it returns (`return inner(d)`): its failing exits are any, so the `catch unreachable` is input's
const std = @import("std");
fn inner(d: usize) !usize {
    if (d == 3) return error.Three;
    return d;
}
fn outer(d: usize) !usize {
    if (d == 0) return error.Zero;
    return inner(d);
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
