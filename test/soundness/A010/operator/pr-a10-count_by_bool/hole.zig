// precision A010 operator: the count starts at the peer's number, so a step by @intFromBool may overflow it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const text = try r.take(try r.takeInt(u16, .little));
    var n: u64 = try r.takeInt(u64, .little);
    for (text) |c| n += @intFromBool(c == '\n');
    return n;
}
