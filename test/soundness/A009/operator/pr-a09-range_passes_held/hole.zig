// precision A009 operator: the check is on another number, so the peer's range end chooses how many passes run
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const n = try r.takeInt(u64, .little);
    const m = try r.takeInt(u64, .little);
    if (m > buf.len) return error.TooLong;
    var total: u8 = 0;
    for (0..n) |k| total +%= @truncate(k);
    return total;
}
