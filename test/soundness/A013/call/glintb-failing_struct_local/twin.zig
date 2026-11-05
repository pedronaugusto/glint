// glint-b: a struct payload (`!Foo`) held in a local the callee made itself, failing only where its divisor is zero, given one at least 1: its `catch` never runs
const std = @import("std");
const Foo = struct { a: usize };
fn outer(d: usize) !Foo {
    if (d == 0) return error.Zero;
    const got: Foo = .{ .a = d };
    return got;
}
pub fn f(r: *std.Io.Reader) !Foo {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
