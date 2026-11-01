// matrix: A021 assignment: a guard stored into a local declared outside the block that takes it, still held when the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, c: bool) void {
    var held: ?L.Guard = null;
    if (c) {
        held = a.acquire();
    }
    var gb = b.acquire();
    defer gb.deinit();
    if (held) |*h| h.deinit();
}
