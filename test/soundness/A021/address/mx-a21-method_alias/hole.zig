// matrix: A021 address: the second lock taken through a name that aliases L.acquire, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const take = L.acquire;
pub fn both(a: *L, b: *L) void {
    var ga = a.acquire();
    defer ga.deinit();
    var gb = take(b);
    defer gb.deinit();
}
