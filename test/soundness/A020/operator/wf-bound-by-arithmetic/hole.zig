// warp-fast: the bound is computed from the input by arithmetic and a
// shift: as long as the input says, with no cancellation point.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const raw = try r.takeInt(u32, .little);
    const n: u64 = (@as(u64, raw) << 8) | 0xff;
    var t: u64 = 0;
    var i: u64 = 0;
    while (i < n) : (i += 1) t +%= i;
    return t;
}
