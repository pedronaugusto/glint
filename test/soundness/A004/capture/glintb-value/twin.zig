// glint-b: A004 capture (value): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(maybe: ?u16) u16 {
    if (maybe) |i| return i +| 1;
    return 0;
}
