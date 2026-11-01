// review 6: a20/e22_flag_switch_prong.zig
const std = @import("std");
// The flag given false in a switch prong input chooses.
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    var total: u64 = 0;
    while (more) {
        total +%= 1;
        switch (total -% seed) {
            0 => more = false,
            else => {},
        }
    }
    return total;
}
