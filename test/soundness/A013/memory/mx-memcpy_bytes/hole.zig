// matrix: a peer's bytes copied by @memcpy into a local, then asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    @memcpy(&buf, try r.take(4));
    std.debug.assert(buf[0] < 4);
    return buf[0];
}
