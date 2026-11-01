// warp-fast: the same loop asks for cancellation each pass.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader, small: bool) !u64 {
    const n: u64 = switch (small) {
        true => 4,
        false => try r.takeInt(u64, .little),
    };
    var t: u64 = 0;
    while (t != n) {
        try io.checkCancel();
        t +%= 1;
    }
    return t;
}
