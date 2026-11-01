// matrix: A021 operator: the lock reached by pointer arithmetic, taken after the first guard is released
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(locks: [*]L) void {
    var ga = locks[0].acquire();
    ga.deinit();
    var gb = (locks + 1)[0].acquire();
    defer gb.deinit();
}
