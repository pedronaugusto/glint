// The guard the helper's record holds is released before b is taken.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { guard: L.Guard, log: std.ArrayList(u8) };
fn lockLogged(l: *L) Held {
    return .{ .guard = l.acquire(), .log = .empty };
}
pub fn both(a: *L, b: *L, gpa: std.mem.Allocator) void {
    var held = lockLogged(a);
    held.log.deinit(gpa);
    held.guard.deinit();
    var h = b.acquire();
    h.deinit();
}
