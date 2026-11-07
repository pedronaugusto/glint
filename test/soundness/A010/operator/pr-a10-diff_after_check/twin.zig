// precision A010 operator: a number checked at least another and then unequal to it is above it, so their difference less one is within the type
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const a = try r.takeInt(u64, .little);
    const b = try r.takeInt(u64, .little);
    if (a < b) return 0;
    if (a == b) return 0;
    return a - b - 1;
}
