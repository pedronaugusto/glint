// matrix: A021 destructure: a guard written by a destructure inside a block into a local outside it, still held when the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, c: bool) u32 {
    var held: ?L.Guard = null;
    var count: u32 = 0;
    if (c) {
        held, count = .{ a.acquire(), 1 };
    }
    var gb = b.acquire();
    defer gb.deinit();
    if (held) |*h| h.deinit();
    return count;
}
