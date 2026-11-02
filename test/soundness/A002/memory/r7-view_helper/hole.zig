// A live guard duplicated through the program's own byte view: both copies are released.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn bytes(p: anytype) []u8 { return std.mem.asBytes(p); }
pub fn f(l: *L) void {
    var g = l.acquire();
    defer g.deinit();
    var dup: L.Guard = undefined;
    @memcpy(bytes(&dup), bytes(&g));
    dup.deinit();
}
