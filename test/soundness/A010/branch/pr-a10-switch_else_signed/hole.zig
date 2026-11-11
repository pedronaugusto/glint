// precision A010 branch: a signed subject past 0 and 1 may be below zero, so the else prong's difference overflows at the least value
const std = @import("std");
pub fn f(r: *std.Io.Reader) !i64 {
    const n = try r.takeInt(i64, .little);
    return switch (n) {
        0, 1 => 0,
        else => n - 2,
    };
}
