// A scalar's raw integer copied out through the program's own byte view of it.
const std = @import("std");
const Index = @import("aegis").id.Id(struct {}, u16);
fn bytes(p: anytype) []const u8 { return std.mem.asBytes(p); }
pub fn f(i: Index) u16 {
    var v: u16 = 0;
    @memcpy(std.mem.asBytes(&v), bytes(&i));
    return v + 1;
}
