// glint-b: A002 destructure (tuple): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) void {
    const a, const b = .{ h.n, h.n };
    _ = .{ a, b };
}
