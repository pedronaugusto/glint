// glint-b: A002 call (helper): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
fn keep(v: anytype) void {
    var copy = v.*;
    copy.deinit();
}
pub fn f(h: *H) void {
    keep(&h.s);
}
