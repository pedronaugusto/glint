// A plain integer copied through the program's own byte view.
const std = @import("std");
fn bytes(p: anytype) []const u8 { return std.mem.asBytes(p); }
pub fn f(i: u16) u16 {
    var v: u16 = 0;
    @memcpy(std.mem.asBytes(&v), bytes(&i));
    return v + 1;
}
