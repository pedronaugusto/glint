// The same view helper of a field, the field a plain integer: no guard duplicated.
const std = @import("std");
const Holder = struct { g: u64 };
fn bytesOf(h: *Holder) []u8 {
    return std.mem.asBytes(&h.g);
}
pub fn f(x: u64) u64 {
    var h: Holder = .{ .g = x };
    var dup: u64 = undefined;
    @memcpy(std.mem.asBytes(&dup), bytesOf(&h));
    return dup;
}
