// glint-b (glint-c's probe): a struct payload (`!Foo`) whose error comes from a call it holds in a local and returns: its failing exits are any, so the `catch unreachable` is input's
const std = @import("std");
const Foo = struct { a: usize };
fn inner(d: usize) !Foo {
    if (d == 3) return error.Three;
    return .{ .a = d };
}
fn outer(d: usize) !Foo {
    if (d == 0) return error.Zero;
    const got = inner(d);
    return got;
}
pub fn f(r: *std.Io.Reader) !Foo {
    const in = try r.take(8);
    return outer(@as(usize, in[0]) + 1) catch unreachable;
}
