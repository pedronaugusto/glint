// warp-fast: the pass's cancellation point runs once in every 4096 passes
// (`i & 4095 == 0`, `i` stepped by one each pass), as warp's marked.zig codes.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    var t: u64 = 0;
    var i: usize = 0;
    while (t != n) : (i += 1) {
        if (i & 4095 == 0) try io.checkCancel();
        t +%= 1;
    }
    return t;
}
