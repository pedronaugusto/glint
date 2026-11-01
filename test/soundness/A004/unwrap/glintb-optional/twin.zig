// glint-b: A004 unwrap (optional): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(maybe: ?u16) u16 {
    return maybe.? +| 1;
}
