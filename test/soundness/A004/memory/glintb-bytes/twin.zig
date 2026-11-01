// glint-b: A004 memory (bytes): the same shape made safe, which must stay clean
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: u16) u16 {
    var v: u16 = 0;
    @memcpy(std.mem.asBytes(&v), std.mem.asBytes(&i));
    return v +| 1;
}
