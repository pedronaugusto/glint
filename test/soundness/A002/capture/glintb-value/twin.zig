// glint-b: A002 capture (value): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(o: ?*H) u32 {
    if (o) |h| return h.n;
    return 0;
}
