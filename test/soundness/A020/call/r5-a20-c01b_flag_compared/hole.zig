// review 5: a20/c01b_flag_compared.zig
const std = @import("std");
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    var total: u64 = 0;
    while (more) {
        total +%= 1;
        more = total != seed;
    }
    return total;
}
