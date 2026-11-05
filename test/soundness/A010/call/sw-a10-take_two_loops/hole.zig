// A010: two loops each over up to 65535 bytes step one u16 count: 131070 passes overflow it
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u16 {
    const text = try r.take(try r.takeInt(u16, .little));
    var n: u16 = 0;
    for (text) |c| n += @intFromBool(c == '\n');
    for (text) |c| n += @intFromBool(c == '\r');
    return n;
}
