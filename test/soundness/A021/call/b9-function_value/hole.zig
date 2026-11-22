// A021: the acquisition held by a const as a function value and called: a finding.
const aegis = @import("aegis");
const Counter = aegis.Guarded(u32);
const take = Counter.acquire;
pub fn bump(g: *Counter) void {
    var guard = take(g);
    defer guard.deinit();
    guard.value().* += 1;
}
