// review 5: a09/d02b_no_shift.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var x: i64 = try r.takeInt(i64, .little);
    var total: u64 = 0;
    while (x != 0) {
        total +%= 1;
        x -= 1;
    }
    return total;
}
