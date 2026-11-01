// glint-b: A002 operator (binary): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, c: bool) u32 {
    return if (c and h.n > 0) h.n else 0;
}
