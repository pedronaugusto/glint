// glint-b: a struct payload (`!Foo`) whose callee fails only where its divisor is zero, given one at least 1: its `catch` never runs
const std = @import("std");
const Foo = struct { a: usize };
fn outer(d: usize) !Foo {
    if (d == 0) return error.Zero;
    return .{ .a = d };
}
pub fn f(r: *std.Io.Reader) !Foo {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
