// precision A010 branch: a labeled switch's continue enters the else prong with another value, so the subject may still be 0 or 1 there
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    return sw: switch (n) {
        0, 1 => continue :sw 7,
        else => n - 2,
    };
}
