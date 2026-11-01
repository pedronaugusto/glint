// glint-b: A002 operator (binary): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, c: bool) void {
    var copy = if (c and h.n > 0) h.s else h.s;
    copy.deinit();
}
