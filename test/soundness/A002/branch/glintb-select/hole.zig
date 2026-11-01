// glint-b: A002 branch (select): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H, k: u8) void {
    var copy = switch (k) {
        0 => h.s,
        else => h.s,
    };
    copy.deinit();
}
