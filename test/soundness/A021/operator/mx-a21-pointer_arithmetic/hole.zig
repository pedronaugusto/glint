// matrix: A021 operator: the second lock reached by pointer arithmetic on a many-item pointer, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(locks: [*]L) void {
    var ga = locks[0].acquire();
    defer ga.deinit();
    var gb = (locks + 1)[0].acquire();
    defer gb.deinit();
}
