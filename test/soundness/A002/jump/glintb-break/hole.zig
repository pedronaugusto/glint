// glint-b: A002 jump (break): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) void {
    var copy = blk: {
        break :blk h.s;
    };
    copy.deinit();
}
