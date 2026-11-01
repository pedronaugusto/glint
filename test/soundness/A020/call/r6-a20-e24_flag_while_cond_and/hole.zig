// review 6: a20/e24_flag_while_cond_and.zig
const std = @import("std");
// The flag is one operand of the condition.
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    var total: u64 = 0;
    while (more and total < std.math.maxInt(u64)) {
        total +%= 1;
        if (total == seed) more = false;
    }
    return total;
}
