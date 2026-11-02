// A plain integer copied by std's copyForwards, then used in arithmetic.
const std = @import("std");
pub fn f(i: u16) u16 {
    var v: u16 = 0;
    std.mem.copyForwards(u8, std.mem.asBytes(&v), std.mem.asBytes(&i));
    return v + 1;
}
