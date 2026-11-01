// warp-fast: the same loop asks for cancellation each pass.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const raw = try r.takeInt(u32, .little);
    const n: u64 = (@as(u64, raw) << 8) | 0xff;
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try io.checkCancel();
        t +%= i;
    }
    return t;
}
