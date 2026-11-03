// An array of optional guards from a helper, one tested in the return: none is released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockBoth(a: *L, b: *L) [2]?L.Guard {
    return .{ a.tryAcquire(), b.tryAcquire() };
}
pub fn f(a: *L, b: *L) bool {
    const gs = lockBoth(a, b);
    return gs[0] != null;
}
