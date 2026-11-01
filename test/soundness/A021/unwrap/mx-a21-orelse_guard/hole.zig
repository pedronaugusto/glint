// matrix: A021 unwrap: two guards each unwrapped from tryAcquire by orelse, both held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = a.tryAcquire() orelse return;
    defer ga.deinit();
    var gb = b.tryAcquire() orelse return;
    defer gb.deinit();
}
