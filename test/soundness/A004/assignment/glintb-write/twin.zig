// glint-b: A004 assignment (write): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16) u16 {
    var v: u16 = 0;
    v = i;
    return v +| 1;
}
