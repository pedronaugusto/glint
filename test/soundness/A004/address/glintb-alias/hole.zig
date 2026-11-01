// glint-b: A004 address (alias): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    const p = &i;
    return p.raw() + 1;
}
