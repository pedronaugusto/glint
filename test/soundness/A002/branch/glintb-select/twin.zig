// glint-b: A002 branch (select): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, k: u8) u32 {
    return switch (k) {
        0 => h.n,
        else => 0,
    };
}
