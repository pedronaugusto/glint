// warp-fast: a loop bound by input that checks the Io its parameter holds four fields down
const std = @import("std");
const D = struct { io: std.Io };
const C = struct { d: D };
const B = struct { c: C };
pub const A = struct { b: B };
pub fn spin(a: *A, r: *std.Io.Reader) !u64 {
    const seed = try r.takeInt(u64, .little);
    var total: u64 = 0;
    while (total != seed) {
        total +%= 1;
        try a.b.c.d.io.checkCancel();
    }
    return total;
}
