// warp-fast: each unrolled loop asks for cancellation each pass.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    var t: u64 = 0;
    inline for (.{ 1, 2 }) |step| {
        var i: u64 = 0;
        while (i < n) : (i += step) {
            try io.checkCancel();
            t +%= i;
        }
    }
    return t;
}
