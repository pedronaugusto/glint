// warp-fast: the input-bound loop sits inside an inline for's body,
// once per unrolled value, with no cancellation point.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const n = try r.takeInt(u64, .little);
    var t: u64 = 0;
    inline for (.{ 1, 2 }) |step| {
        var i: u64 = 0;
        while (i < n) : (i += step) t +%= i;
    }
    return t;
}
