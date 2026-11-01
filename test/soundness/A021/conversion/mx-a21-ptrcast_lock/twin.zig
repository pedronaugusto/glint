// matrix: A021 conversion: the lock reached through @ptrCast, taken after the first guard is released
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, raw: *anyopaque) void {
    var ga = a.acquire();
    ga.deinit();
    const b: *L = @ptrCast(@alignCast(raw));
    var gb = b.acquire();
    defer gb.deinit();
}
