// review 6: a20/e33_point_caught_ignored.zig
const std = @import("std");
// The point's error.Canceled is swallowed: the loop goes on after a cancel.
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        io.checkCancel() catch {};
        t +%= i;
    }
    return t;
}
