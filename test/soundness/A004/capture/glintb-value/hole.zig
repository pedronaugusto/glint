// glint-b: A004 capture (value): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(maybe: ?Index) u16 {
    if (maybe) |i| return i.raw() + 1;
    return 0;
}
