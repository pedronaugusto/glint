// matrix: A021 aggregate: a guard put into a struct literal stored in a local outside its block, still held when the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Held = struct { guard: L.Guard, count: u32 };
pub fn both(a: *L, b: *L, c: bool) void {
    var held: ?Held = null;
    if (c) {
        held = .{ .guard = a.acquire(), .count = 1 };
    }
    var gb = b.acquire();
    defer gb.deinit();
    if (held) |*h| h.guard.deinit();
}
