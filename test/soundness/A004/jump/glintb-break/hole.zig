// glint-b: A004 jump (break): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    const v = blk: {
        break :blk i.raw();
    };
    return v + 1;
}
