// glint-b: A004 jump (break): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16) u16 {
    const v = blk: {
        break :blk i;
    };
    return v +| 1;
}
