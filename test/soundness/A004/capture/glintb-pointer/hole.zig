// glint-b: A004 capture (pointer): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(is: []Index) u16 {
    var sum: u16 = 0;
    for (is) |*i| sum +%= i.raw();
    return sum;
}
