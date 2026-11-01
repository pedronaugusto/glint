// matrix: A021 aggregate: the guard in a struct literal released before the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { guard: L.Guard, count: u32 };
pub fn both(a: *L, b: *L, c: bool) void {
    var held: ?Held = null;
    if (c) {
        held = .{ .guard = a.acquire(), .count = 1 };
    }
    if (held) |*h| h.guard.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
