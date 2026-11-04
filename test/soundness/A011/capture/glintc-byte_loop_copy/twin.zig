// The same byte loop copying a raw count into another raw count.
const std = @import("std");
pub fn f(ns: i96) i96 {
    var d: i96 = 0;
    for (std.mem.asBytes(&d), std.mem.asBytes(&ns)) |*b, s| b.* = s;
    return d;
}
