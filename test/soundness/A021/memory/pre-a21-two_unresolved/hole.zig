// Two acquisitions on locks read by @atomicLoad: neither resolves, and with no known acquisition in the function
// neither is reported (DangerShapes.zig:1605-1610), though a's guard is held while b is taken.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn both(sa: *?*L, sb: *?*L) void {
    const a = @atomicLoad(?*L, sa, .acquire).?;
    const b = @atomicLoad(?*L, sb, .acquire).?;
    var g = a.acquire();
    defer g.deinit();
    var h = b.acquire();
    defer h.deinit();
}
