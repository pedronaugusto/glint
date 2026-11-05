const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const text = try r.take(try r.takeInt(u32, .little));
    var n: u32 = 0;
    for (text) |a| n += @intFromBool(a == 0);
    return n;
}
