// review 6: a20/e20_flag_through_ptr.zig
const std = @import("std");
// The flag set false through a pointer to it, under a condition input decides.
pub fn churn(io: std.Io, r: *std.Io.Reader) !u64 {
    _ = io;
    const seed = try r.takeInt(u64, .little);
    var more = true;
    const p = &more;
    var total: u64 = 0;
    while (more) {
        total +%= 1;
        if (total == seed) p.* = false;
    }
    return total;
}
