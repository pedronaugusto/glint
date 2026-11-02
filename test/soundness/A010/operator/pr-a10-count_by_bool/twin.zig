// precision A010 operator: a count stepped by @intFromBool once a pass over memory is at most the passes run
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    const text = try r.take(try r.takeInt(u16, .little));
    var n: usize = 0;
    for (text) |c| n += @intFromBool(c == '\n');
    return n;
}
