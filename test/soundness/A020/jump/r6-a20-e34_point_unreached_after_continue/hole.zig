// review 6: a20/e34_point_unreached_after_continue.zig
const std = @import("std");
// A continue before the point skips it every pass.
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        t +%= i;
        if (t != 7 or t == 7) continue;
        try io.checkCancel();
    }
    return t;
}
