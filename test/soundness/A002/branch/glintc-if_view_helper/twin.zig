// The same if over two views, of a plain integer: no guard duplicated.
const std = @import("std");
fn bytes(p: anytype, whole: bool) []u8 {
    return if (whole) std.mem.asBytes(p) else std.mem.asBytes(p)[0..];
}
pub fn f(x: u64, whole: bool) u64 {
    var dup: u64 = 0;
    var y = x;
    @memcpy(std.mem.asBytes(&dup), bytes(&y, whole));
    return dup;
}
