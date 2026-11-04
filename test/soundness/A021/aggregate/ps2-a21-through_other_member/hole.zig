// A helper returns a record holding a's guard beside a list: the list's deinit is no release of the guard, so b is
// taken while held.guard still holds a.
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
    var h = b.acquire();
    h.deinit();
    held.guard.deinit();
}
