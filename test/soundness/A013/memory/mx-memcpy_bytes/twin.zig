// matrix: the program's own bytes copied by @memcpy into a local, then asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    @memcpy(&buf, "abcd");
    std.debug.assert(buf[0] != 0);
    return buf[0] +% try r.takeByte();
}
