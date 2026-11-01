// glint-b: A004 capture (pointer): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(is: []u16) u16 {
    var sum: u16 = 0;
    for (is) |*i| sum +%= i.*;
    return sum;
}
