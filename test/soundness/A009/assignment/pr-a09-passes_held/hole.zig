// precision A009 assignment: the loop stops at the peer's number, not the memory's length: the peer chooses how long it runs
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    var i: u64 = try r.takeInt(u64, .little);
    const end = try r.takeInt(u64, .little);
    var total: u8 = 0;
    while (i < end) : (i += 2) total +%= @truncate(i +% buf.len);
    return total;
}
