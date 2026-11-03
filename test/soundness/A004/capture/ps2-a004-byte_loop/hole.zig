// A scalar's raw integer copied out by the program's own byte loop.
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
pub fn f(i: Index) u16 {
    var v: u16 = 0;
    for (std.mem.asBytes(&v), std.mem.asBytes(&i)) |*d, s| d.* = s;
    return v + 1;
}
