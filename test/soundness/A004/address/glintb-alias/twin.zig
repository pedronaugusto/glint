// glint-b: A004 address (alias): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16) u16 {
    const p = &i;
    return p.* +| 1;
}
