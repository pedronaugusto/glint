// glint-b: A002 inline_loop (names): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) u32 {
    var sum: u32 = 0;
    inline for (.{"n"}) |name| sum +%= @field(h, name);
    return sum;
}
