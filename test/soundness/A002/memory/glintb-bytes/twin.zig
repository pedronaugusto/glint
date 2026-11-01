// glint-b: A002 memory (bytes): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, out: *u32) void {
    @memcpy(std.mem.asBytes(out), std.mem.asBytes(&h.n));
}
