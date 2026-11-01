// glint-b: A004 destructure (tuple): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16) u16 {
    const a, const b = .{ i, @as(u16, 1) };
    return a +| b;
}
