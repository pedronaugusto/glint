// warp-fast: a loop bound by input with no cancellation point, given an Io four fields down
const std = @import("std");
const D = struct { io: std.Io };
const C = struct { d: D };
const B = struct { c: C };
pub const A = struct { b: B };
pub fn spin(a: *A, r: *std.Io.Reader) !u64 {
    _ = a;
    const seed = try r.takeInt(u64, .little);
    var total: u64 = 0;
    while (total != seed) {
        total +%= 1;
    }
    return total;
}
