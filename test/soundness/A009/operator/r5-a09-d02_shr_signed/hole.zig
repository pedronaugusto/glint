// review 5: a09/d02_shr_signed.zig
const std = @import("std");
// An arithmetic shift right of a negative number never reaches 0: -1 >> 1 is -1.
pub fn f(r: *std.Io.Reader) !u64 {
    var x: i64 = try r.takeInt(i64, .little);
    var total: u64 = 0;
    while (x != 0) {
        total +%= 1;
        x >>= 1;
    }
    return total;
}
