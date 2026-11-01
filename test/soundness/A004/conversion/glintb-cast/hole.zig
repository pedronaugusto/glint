// glint-b: A004 conversion (cast): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(v: u16) Index {
    return @enumFromInt(v);
}
