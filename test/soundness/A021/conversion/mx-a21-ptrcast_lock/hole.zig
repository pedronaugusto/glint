// matrix: A021 conversion: the second lock reached through @ptrCast of an opaque pointer, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, raw: *anyopaque) void {
    var ga = a.acquire();
    defer ga.deinit();
    const b: *L = @ptrCast(@alignCast(raw));
    var gb = b.acquire();
    defer gb.deinit();
}
