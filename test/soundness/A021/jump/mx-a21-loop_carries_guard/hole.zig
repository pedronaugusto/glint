// matrix: A021 jump: a guard taken in one pass of a loop is still held in the next pass, where an earlier statement takes a second lock
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var held: ?L.Guard = null;
    for (0..2) |i| {
        if (i == 1) {
            var gb = b.acquire();
            gb.deinit();
        }
        if (i == 0) held = a.acquire();
    }
    if (held) |*h| h.deinit();
}
