// precision A010 assignment: the check is on another number, so the variable's step past the peer's u64 overflows
const std = @import("std");
pub fn f(r: *std.Io.Reader, buf: []const u8) !u64 {
    const n = try r.takeInt(u64, .little);
    const at = try r.takeInt(u64, .little);
    var i = n | 1;
    if (at < buf.len) i += 1;
    return i;
}
