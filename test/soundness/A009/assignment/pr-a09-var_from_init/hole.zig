// precision A009 assignment: a write between the check and the index: the peer's number indexes the memory
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u8 {
    const n = try r.takeInt(u64, .little);
    var i = n | 1;
    if (i >= buf.len) return 0;
    i = n | 2;
    return buf[i];
}
