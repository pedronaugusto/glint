// matrix: A021 unwrap: the guard unwrapped by orelse released before the second lock is taken
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = a.tryAcquire() orelse return;
    ga.deinit();
    var gb = b.tryAcquire() orelse return;
    defer gb.deinit();
}
