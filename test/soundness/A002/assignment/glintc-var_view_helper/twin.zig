// The same view helper keeping its view in a var, over a plain integer: no guard duplicated.
const std = @import("std");
fn bytes(p: anytype) []u8 {
    var b: []u8 = std.mem.asBytes(p);
    _ = &b;
    return b;
}
pub fn f(x: u64) u64 {
    var dup: u64 = 0;
    var y = x;
    @memcpy(std.mem.asBytes(&dup), bytes(&y));
    return dup;
}
