// glint-b: A004 memory (bytes): the unsafe shape, which must flag
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    var v: u16 = 0;
    @memcpy(std.mem.asBytes(&v), std.mem.asBytes(&i));
    return v + 1;
}
