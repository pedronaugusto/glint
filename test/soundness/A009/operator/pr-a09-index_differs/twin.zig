// precision A009 operator: a position at most the memory's length and unequal to it is below it, where it indexes
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const n = try r.takeInt(u64, .little);
    const i = @min(n, buf.len);
    if (i == buf.len) return 0;
    return buf[i];
}
