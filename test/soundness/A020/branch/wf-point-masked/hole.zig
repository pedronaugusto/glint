// warp-fast: the masked point's counter is stepped on one pass only: from
// then on `i & 4095` is 1 and no pass reaches the point.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: usize = 0;
    while (t != n) {
        if (i & 4095 == 0) try io.checkCancel();
        if (t == 0) i += 1;
        t +%= 1;
    }
    return t;
}
