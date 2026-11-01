// glint-b: A004 field (named): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
const Box = struct { i: u16 };
pub fn f(b: Box) u16 {
    return @field(b, "i") +| 1;
}
