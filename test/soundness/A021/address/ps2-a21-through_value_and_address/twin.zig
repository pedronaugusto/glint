// The guard written through the out parameter is released before b is taken.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockInto(l: *L, out: *L.Guard) std.ArrayList(u8) {
    out.* = l.acquire();
    return .empty;
}
pub fn both(a: *L, b: *L, gpa: std.mem.Allocator) void {
    var g: L.Guard = undefined;
    var notes = lockInto(a, &g);
    notes.deinit(gpa);
    g.deinit();
    var h = b.acquire();
    h.deinit();
}
