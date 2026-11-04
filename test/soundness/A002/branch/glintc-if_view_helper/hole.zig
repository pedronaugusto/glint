// A view helper whose return is an if over two views of its parameter: a guard duplicated through it.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn bytes(p: anytype, whole: bool) []u8 {
    return if (whole) std.mem.asBytes(p) else std.mem.asBytes(p)[0..];
}
pub fn f(l: *L, whole: bool) void {
    var g = l.acquire();
    defer g.deinit();
    var dup: L.Guard = undefined;
    @memcpy(std.mem.asBytes(&dup), bytes(&g, whole));
    dup.deinit();
}
