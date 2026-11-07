// precision A010 branch: a switch's else prong holds where the subject matched none of the prongs' values, so an unsigned subject past 0 and 1 is at least 2
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    return switch (n) {
        0, 1 => 0,
        else => n - 2,
    };
}
