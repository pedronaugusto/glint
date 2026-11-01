// matrix: A021 destructure: the destructured guard released before the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, c: bool) u32 {
    var held: ?L.Guard = null;
    var count: u32 = 0;
    if (c) {
        held, count = .{ a.acquire(), 1 };
    }
    if (held) |*h| h.deinit();
    var gb = b.acquire();
    defer gb.deinit();
    return count;
}
