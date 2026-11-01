// glint-b: A004 aggregate (literal): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16) [2]u16 {
    const pair = .{ i, @as(u16, 1) };
    return .{ pair[0] +| 1, pair[1] };
}
