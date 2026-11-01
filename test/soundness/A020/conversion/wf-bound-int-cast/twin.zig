// warp-fast: the same loop asks for cancellation on each pass.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const n: usize = @intCast(try r.takeInt(u32, .little));
    var t: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try io.checkCancel();
        t +%= i;
    }
    return t;
}
