// A program helper gives a tuple holding a guard by value: the guard is never released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockCounted(l: *L) struct { L.Guard, u32 } {
    return .{ l.acquire(), 1 };
}
pub fn f(l: *L) u32 {
    const g, const n = lockCounted(l);
    _ = g;
    return n;
}
