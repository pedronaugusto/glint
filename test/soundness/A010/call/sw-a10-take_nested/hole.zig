// A010: a count stepped in an inner loop runs len*len passes, past a u32
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const text = try r.take(try r.takeInt(u32, .little));
    var n: u32 = 0;
    for (text) |a| for (text) |b| {
        n += @intFromBool(a == b);
    };
    return n;
}
