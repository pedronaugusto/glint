const std = @import("std");
pub fn f(i: u16) u16 {
    var v: u16 = 0;
    for (std.mem.asBytes(&v), std.mem.asBytes(&i)) |*d, s| d.* = s;
    return v + 1;
}
