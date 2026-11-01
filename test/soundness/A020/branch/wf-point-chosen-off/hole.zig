// warp-fast: the pass's only cancellation point is under an `if` whose
// condition is a constant false: no pass reaches it.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const ask = false;
    const n = try r.takeInt(u64, .little);
    var t: u64 = 0;
    while (t != n) {
        if (ask) try io.checkCancel();
        t +%= 1;
    }
    return t;
}
