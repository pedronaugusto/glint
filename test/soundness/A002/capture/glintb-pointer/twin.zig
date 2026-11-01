// glint-b: A002 capture (pointer): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(hs: []H) u32 {
    var sum: u32 = 0;
    for (hs) |*h| sum +%= h.n;
    return sum;
}
