// A guard named in the return only through @TypeOf: a bool is returned, the lock stays held.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) bool {
    var g = l.acquire();
    g.value().* += 1;
    return @sizeOf(@TypeOf(g)) != 0;
}
