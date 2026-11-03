// The tuple's guard released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockCounted(l: *L) struct { L.Guard, u32 } {
    return .{ l.acquire(), 1 };
}
pub fn f(l: *L) u32 {
    var g, const n = lockCounted(l);
    g.deinit();
    return n;
}
