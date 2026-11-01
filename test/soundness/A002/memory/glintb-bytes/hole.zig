// glint-b: A002 memory (bytes): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, out: *S) void {
    @memcpy(std.mem.asBytes(out), std.mem.asBytes(&h.s));
}
