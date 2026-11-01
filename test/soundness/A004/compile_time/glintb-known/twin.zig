// glint-b: A004 compile_time (known): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16) u16 {
    const step = comptime 2;
    return i *| step;
}
