// glint-b: A004 inline_loop (names): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16, j: u16) u16 {
    var sum: u16 = 0;
    inline for (.{ i, j }) |x| sum +|= x;
    return sum;
}
