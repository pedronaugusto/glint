// review 5: a09/d05b_assign_arith.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    var n: u64 = undefined;
    var i: u64 = undefined;
    n = try r.takeInt(u64, .little);
    i = 0;
    const m = n;
    return m * m + i;
}
