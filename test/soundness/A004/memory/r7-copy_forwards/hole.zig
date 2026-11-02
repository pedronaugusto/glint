// A scalar's raw integer copied out by std's copyForwards, then used in arithmetic.
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    var v: u16 = 0;
    std.mem.copyForwards(u8, std.mem.asBytes(&v), std.mem.asBytes(&i));
    return v + 1;
}
