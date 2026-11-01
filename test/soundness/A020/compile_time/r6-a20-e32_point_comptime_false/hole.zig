// review 6: a20/e32_point_comptime_false.zig
const std = @import("std");
const check = false;
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n: u64 = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (check) try io.checkCancel();
        t +%= i;
    }
    return t;
}
