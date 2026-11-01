// warp-fast: the loop's bound is chosen by a switch expression, one prong
// the input itself: the loop has no cancellation point.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader, small: bool) !u64 {
    _ = io;
    const n: u64 = switch (small) {
        true => 4,
        false => try r.takeInt(u64, .little),
    };
    var t: u64 = 0;
    while (t != n) t +%= 1;
    return t;
}
