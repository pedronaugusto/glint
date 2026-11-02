// The guarded value's bytes copied by std's copyForwards: no owner duplicated.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
pub fn f(l: *L) u32 {
    var g = l.acquire();
    defer g.deinit();
    var out: u32 = 0;
    std.mem.copyForwards(u8, std.mem.asBytes(&out), std.mem.asBytes(g.value()));
    return out;
}
