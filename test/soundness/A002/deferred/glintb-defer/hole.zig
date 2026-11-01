// glint-b: A002 deferred (defer): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, out: *S) void {
    defer out.* = h.s;
}
