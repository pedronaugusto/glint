// glint-b: A004 branch (select): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index, c: bool) u16 {
    const v = if (c) i.raw() else 0;
    return v + 1;
}
