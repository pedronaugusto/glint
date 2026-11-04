// A live guard duplicated by the program's own byte loop over two views: both copies are released.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) void {
    var g = l.acquire();
    defer g.deinit();
    var dup: L.Guard = undefined;
    for (std.mem.asBytes(&dup), std.mem.asBytes(&g)) |*d, s| d.* = s;
    dup.deinit();
}
