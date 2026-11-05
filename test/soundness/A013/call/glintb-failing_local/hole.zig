// glint-b (glint-c's probe): a callee whose error comes from a call it holds in a local and returns (`const r = inner(d); return r;`): its failing exits are any, so the `catch unreachable` is input's
const std = @import("std");
fn inner(d: usize) !usize {
    if (d == 3) return error.Three;
    return d;
}
fn outer(d: usize) !usize {
    if (d == 0) return error.Zero;
    const r = inner(d);
    return r;
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
