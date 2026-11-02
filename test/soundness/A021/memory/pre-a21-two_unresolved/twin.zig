const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(sa: *?*L, sb: *?*L) void {
    const a = @atomicLoad(?*L, sa, .acquire).?;
    const b = @atomicLoad(?*L, sb, .acquire).?;
    var g = a.acquire();
    g.deinit();
    var h = b.acquire();
    h.deinit();
}
