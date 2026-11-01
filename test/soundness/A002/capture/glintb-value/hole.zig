// glint-b: A002 capture (value): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(o: ?*H) void {
    if (o) |h| {
        var copy = h.s;
        copy.deinit();
    }
}
