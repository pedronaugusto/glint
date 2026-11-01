// glint-b: A002 aggregate (literal): the same shape made safe, which must stay clean
const std = @import("std");
const S = @import("aegis").Secret(u32);
const H = struct { s: S, n: u32 };
pub fn f(h: *H) [1]u32 {
    return .{h.n};
}
