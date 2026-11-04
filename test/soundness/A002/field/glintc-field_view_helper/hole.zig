// A view helper that views a field of its parameter: a guard held in a record duplicated through it.
const std = @import("std");
const aegis = @import("aegis");
const L = aegis.Guarded(u32);
const Holder = struct { g: L.Guard };
fn bytesOf(h: *Holder) []u8 {
    return std.mem.asBytes(&h.g);
}
pub fn f(l: *L) void {
    var h: Holder = .{ .g = l.acquire() };
    defer h.g.deinit();
    var dup: L.Guard = undefined;
    @memcpy(std.mem.asBytes(&dup), bytesOf(&h));
    dup.deinit();
}
