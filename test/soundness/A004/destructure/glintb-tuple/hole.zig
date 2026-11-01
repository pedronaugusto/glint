// glint-b: A004 destructure (tuple): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    const a, const b = .{ i.raw(), @as(u16, 1) };
    return a + b;
}
