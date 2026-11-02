// The guarded value's bytes copied through the program's own byte view.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
fn bytes(p: anytype) []u8 { return std.mem.asBytes(p); }
pub fn f(l: *L) u32 {
    var g = l.acquire();
    defer g.deinit();
    var out: u32 = 0;
    @memcpy(bytes(&out), bytes(g.value()));
    return out;
}
