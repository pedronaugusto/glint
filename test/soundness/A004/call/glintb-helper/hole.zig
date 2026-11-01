// glint-b: A004 call (helper): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
fn bump(x: anytype) u16 {
    return x.raw() + 1;
}
pub fn f(i: Index) u16 {
    return bump(i);
}
