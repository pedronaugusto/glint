// glint-b: A004 aggregate (literal): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) [2]u16 {
    const pair = .{ i.raw(), @as(u16, 1) };
    return .{ pair[0] + 1, pair[1] };
}
