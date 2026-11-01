// warp-fast: the input bound is converted (@intCast) before the loop
// compares against it: the loop is still as long as the input says, with no cancellation point.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const n: usize = @intCast(try r.takeInt(u32, .little));
    var t: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) t +%= i;
    return t;
}
