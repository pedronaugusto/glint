// matrix: A021 call: the second lock taken through @call, while the first guard is held
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(a: *L, b: *L) void {
    var ga = a.acquire();
    defer ga.deinit();
    var gb = @call(.auto, L.acquire, .{b});
    defer gb.deinit();
}
