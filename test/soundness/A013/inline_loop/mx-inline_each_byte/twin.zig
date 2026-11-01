// matrix: an inline for refuses each byte a peer sent that is out of range
const std = @import("std");
pub fn f(r: *std.Io.Reader) ![2]u8 {
    var buf: [2]u8 = undefined;
    try r.readSliceAll(&buf);
    inline for (0..2) |i| if (buf[i] >= 128) return error.NotAscii;
    return buf;
}
