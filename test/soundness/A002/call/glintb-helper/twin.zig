// glint-b: A002 call (helper): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
fn keep(v: anytype) u32 {
    const copy = v.*;
    return copy;
}
pub fn f(h: *H) u32 {
    return keep(&h.n);
}
