// A helper writes a's guard through its out parameter and returns a list: the list it binds holds no guard, so its
// deinit is no release of g, and b is taken while g holds a.
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
    var h = b.acquire();
    h.deinit();
    g.deinit();
}
