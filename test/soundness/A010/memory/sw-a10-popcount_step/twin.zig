const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    var n: usize = 0;
    for (r.buffer) |c| n += @intFromBool(c == 0);
    return n;
}
