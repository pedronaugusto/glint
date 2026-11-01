// glint-b: A004 inline_loop (names): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index, j: Index) u16 {
    var sum: u16 = 0;
    inline for (.{ i, j }) |x| sum += x.raw();
    return sum;
}
