// glint-b: A002 capture (pointer): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(hs: []H) void {
    for (hs) |*h| {
        var copy = h.s;
        copy.deinit();
    }
}
