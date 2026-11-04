// The same loop over two plain integers.
const std = @import("std");
pub fn f(x: u64) u64 {
    var dup: u64 = 0;
    for (std.mem.asBytes(&dup), std.mem.asBytes(&x)) |*d, s| d.* = s;
    return dup;
}
