// review 6: a20/e21_flag_in_callee.zig
const std = @import("std");
fn stop(flag: *bool, total: u64, seed: u64) void {
    if (total == seed) flag.* = false;
}
// The flag set false by a callee under a condition input decides.
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    var total: u64 = 0;
    while (more) {
        total +%= 1;
        stop(&more, total, seed);
    }
    return total;
}
