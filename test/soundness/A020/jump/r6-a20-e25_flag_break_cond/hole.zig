// review 6: a20/e25_flag_break_cond.zig
const std = @import("std");
// A labeled block's break decides whether the flag is given false.
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    var total: u64 = 0;
    while (more) {
        total +%= 1;
        blk: {
            if (total != seed) break :blk;
            more = false;
        }
    }
    return total;
}
