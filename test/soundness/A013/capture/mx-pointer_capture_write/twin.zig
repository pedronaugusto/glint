// matrix: constants written through a for loop's pointer capture, the array then asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var buf: [2]u8 = .{ 0, 0 };
    for (&buf, 0..) |*p, i| p.* = @intCast(i);
    std.debug.assert(buf[0] < 4);
    return buf[1] +% try r.takeByte();
}
