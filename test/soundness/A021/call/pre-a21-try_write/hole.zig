// tryWrite takes the lock (try*, as the rule's own list says) while a's guard is held, not ranked.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const R = aegis.SpinRwGuarded(u32);
pub fn both(a: *L, b: *R) void {
    var g = a.acquire();
    defer g.deinit();
    if (b.tryWrite()) |w| {
        var held = w;
        held.deinit();
    }
}
