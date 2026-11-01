// matrix: an inline for asserts each byte a peer sent
const std = @import("std");
pub fn f(r: *std.Io.Reader) ![2]u8 {
    var buf: [2]u8 = undefined;
    try r.readSliceAll(&buf);
    inline for (0..2) |i| std.debug.assert(buf[i] < 128);
    return buf;
}
