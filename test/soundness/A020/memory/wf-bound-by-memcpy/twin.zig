// warp-fast: the same loop asks for cancellation each pass.
const std = @import("std");
pub fn spin(io: std.Io, r: *std.Io.Reader) !u64 {
    const bytes = try r.takeArray(8);
    var n: u64 = 0;
    @memcpy(std.mem.asBytes(&n), bytes);
    var t: u64 = 0;
    while (t != n) {
        try io.checkCancel();
        t +%= 1;
    }
    return t;
}
