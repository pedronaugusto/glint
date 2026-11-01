// glint-b: A002 jump (break): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) u32 {
    const v = blk: {
        break :blk h.n;
    };
    return v;
}
