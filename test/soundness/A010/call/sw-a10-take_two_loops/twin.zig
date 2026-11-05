const std = @import("std");
pub fn f(r: *std.Io.Reader) !u16 {
    const text = try r.take(try r.takeInt(u16, .little));
    var n: u16 = 0;
    for (text) |c| n += @intFromBool(c == '\n');
    return n;
}
