// matrix: A021 assignment: the stored guard released before the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L, c: bool) void {
    var held: ?L.Guard = null;
    if (c) {
        held = a.acquire();
    }
    if (held) |*h| h.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
