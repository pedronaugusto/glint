// A010: a count stepped by up to 8 a pass over memory of any length: 8 times its passes may pass a usize
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    var n: usize = 0;
    for (r.buffer) |c| n += @popCount(c);
    return n;
}
