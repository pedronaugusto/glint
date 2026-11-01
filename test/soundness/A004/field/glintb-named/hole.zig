// glint-b: A004 field (named): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
const Box = struct { i: Index };
pub fn f(b: Box) u16 {
    return @field(b, "i").raw() + 1;
}
