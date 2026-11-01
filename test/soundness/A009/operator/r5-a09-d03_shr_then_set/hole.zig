// review 5: a09/d03_shr_then_set.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const seed = try r.takeInt(u64, .little);
    var x: u64 = seed;
    var total: u64 = 0;
    while (x != 0) {
        total +%= 1;
        x >>= 1;
        x |= seed;
    }
    return total;
}
