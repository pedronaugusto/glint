// A live guard duplicated by std's copyForwards over its bytes: both copies are released.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) void {
    var g = l.acquire();
    defer g.deinit();
    var dup: L.Guard = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&dup), std.mem.asBytes(&g));
    dup.deinit();
}
