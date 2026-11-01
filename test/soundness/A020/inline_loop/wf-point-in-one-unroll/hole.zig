// warp-fast: an inline for unrolls the pass's body; the cancellation
// point sits in unrolled copies guarded by a comptime value that is never true.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    var t: u64 = 0;
    while (t < n) {
        inline for (.{ false, false }) |ask| {
            if (ask) try io.checkCancel();
            t +%= 1;
        }
    }
    return t;
}
