// review 6: a20/e23_flag_destructure.zig
const std = @import("std");
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    var total: u64 = 0;
    var x: u64 = 0;
    while (more) {
        total +%= 1;
        if (total == seed) {
            more, x = .{ false, 1 };
        }
    }
    return total + x;
}
