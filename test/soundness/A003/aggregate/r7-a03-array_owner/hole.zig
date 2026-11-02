// Guards the program's helper gives in an array are never released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn lockBoth(a: *L, b: *L) [2]L.Guard {
    return .{ a.acquire(), b.acquire() };
}
pub fn f(a: *L, b: *L) void {
    var gs = lockBoth(a, b);
    gs[0].value().* += 1;
}
