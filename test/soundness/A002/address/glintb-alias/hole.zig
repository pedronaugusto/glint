// glint-b: A002 address (alias): the unsafe shape, which must flag
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) void {
    const p = &h.s;
    var copy = p.*;
    copy.deinit();
}
