// precision A009 operator: a range's end the peer sends, checked at most the memory's length first, runs no more passes than the memory holds
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const n = try r.takeInt(u64, .little);
    if (n > buf.len) return error.TooLong;
    var total: u8 = 0;
    for (0..n) |k| total +%= buf[k];
    return total;
}
