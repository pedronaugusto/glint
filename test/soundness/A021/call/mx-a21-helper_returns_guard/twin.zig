// matrix: A021 call: the guard a helper returns, released before the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockOf(l: *L) L.Guard {
    return l.acquire();
}
pub fn both(a: *L, b: *L) void {
    var ga = lockOf(a);
    ga.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
