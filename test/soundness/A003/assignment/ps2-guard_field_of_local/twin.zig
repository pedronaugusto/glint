// The record's guard released.
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Box = struct { g: L.Guard = undefined, n: u32 = 0 };
pub fn f(l: *L) u32 {
    var box: Box = .{};
    box.g = l.acquire();
    defer box.g.deinit();
    box.n = box.g.value().*;
    return box.n;
}
