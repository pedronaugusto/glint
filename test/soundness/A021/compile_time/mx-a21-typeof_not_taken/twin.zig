// matrix: A021 compile_time: an acquire inside @TypeOf is never run, so only one lock is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = a.acquire();
    defer ga.deinit();
    const G = @TypeOf(b.acquire());
    var none: ?G = null;
    _ = &none;
}
