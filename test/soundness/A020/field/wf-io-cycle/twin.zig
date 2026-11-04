// warp-fast: a type that holds an Io through a type that points back to it, read first from the other, its loop checking the Io
const std = @import("std");
pub const A = struct { b: *B, io: std.Io };
pub const B = struct { a: *A };
pub fn first(a: *A, r: *std.Io.Reader) !u64 {
    const seed = try r.takeInt(u64, .little);
    var total: u64 = 0;
    while (total != seed) {
        total +%= 1;
        try a.io.checkCancel();
    }
    return total;
}
pub fn second(b: *B, r: *std.Io.Reader) !u64 {
    const seed = try r.takeInt(u64, .little);
    var total: u64 = 0;
    while (total != seed) {
        total +%= 1;
        try b.a.io.checkCancel();
    }
    return total;
}
