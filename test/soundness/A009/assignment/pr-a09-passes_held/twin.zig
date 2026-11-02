// precision A009 assignment: a position the peer chooses steps toward the memory's length each pass, so the loop runs no more passes than the memory holds
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    var i: u64 = try r.takeInt(u64, .little);
    var total: u8 = 0;
    while (i < buf.len) : (i += 2) total +%= buf[i];
    return total;
}
