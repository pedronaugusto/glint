// review 7 A007: the same type function giving a number.
const std = @import("std");
pub fn run() u32 {
    var n: std.meta.Child(*const u32) = 0;
    n += 1;
    return n;
}
