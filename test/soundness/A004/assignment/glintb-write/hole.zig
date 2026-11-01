// glint-b: A004 assignment (write): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    var v: u16 = 0;
    v = i.raw();
    return v + 1;
}
