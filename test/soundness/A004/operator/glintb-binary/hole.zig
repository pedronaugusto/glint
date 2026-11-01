// glint-b: A004 operator (binary): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index, j: Index) bool {
    return i.raw() + j.raw() > 10;
}
