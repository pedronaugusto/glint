// matrix: A021 address: the lock taken through a name that aliases L.acquire, released before the second is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const take = L.acquire;
pub fn both(a: *L, b: *L) void {
    var ga = take(a);
    ga.deinit();
    var gb = b.acquire();
    defer gb.deinit();
}
