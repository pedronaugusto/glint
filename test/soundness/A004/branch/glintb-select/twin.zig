// glint-b: A004 branch (select): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16, c: bool) u16 {
    const v = if (c) i else 0;
    return v +| 1;
}
