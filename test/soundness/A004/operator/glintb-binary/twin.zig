// glint-b: A004 operator (binary): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index, j: Index) bool {
    return i == j;
}
