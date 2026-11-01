// glint-b: A002 address (alias): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) u32 {
    const p = &h.n;
    return p.*;
}
