// precision A009 operator: the unequal check is on the peer's number, not the position: past the length the position is the length, which indexes past the memory
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const n = try r.takeInt(u64, .little);
    const i = @min(n, buf.len);
    if (n == buf.len) return 0;
    return buf[i];
}
