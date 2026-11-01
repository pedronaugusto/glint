// matrix: A021 address: the second lock reached through a pointer to the pointer that holds it
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = a.acquire();
    defer ga.deinit();
    const slot = &b;
    var gb = slot.*.acquire();
    defer gb.deinit();
}
