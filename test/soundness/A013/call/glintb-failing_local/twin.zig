// glint-b: the same callee returning the error union it made itself: it fails only where its divisor is zero, given one at least 1: its `catch` never runs
const std = @import("std");
fn outer(d: usize) !usize {
    if (d == 0) return error.Zero;
    return d;
}
pub fn f(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
