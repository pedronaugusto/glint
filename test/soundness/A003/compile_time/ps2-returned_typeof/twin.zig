// The guard released before the return.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) bool {
    var g = l.acquire();
    g.value().* += 1;
    g.deinit();
    return @sizeOf(L.Guard) != 0;
}
