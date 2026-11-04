// A live guard duplicated through the program's byte view helper that keeps the view in a var first.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn bytes(p: anytype) []u8 {
    var b: []u8 = std.mem.asBytes(p);
    _ = &b;
    return b;
}
pub fn f(l: *L) void {
    var g = l.acquire();
    defer g.deinit();
    var dup: L.Guard = undefined;
    @memcpy(std.mem.asBytes(&dup), bytes(&g));
    dup.deinit();
}
