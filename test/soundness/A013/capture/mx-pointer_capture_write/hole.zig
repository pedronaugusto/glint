// matrix: input written through a for loop's pointer capture, the array then asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var buf: [2]u8 = .{ 0, 0 };
    for (&buf) |*p| p.* = try r.takeByte();
    std.debug.assert(buf[0] < 4);
    return buf[0];
}
