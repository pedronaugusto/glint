// glint-b: A004 compile_time (known): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    const step = comptime 2;
    return i.raw() * step;
}
