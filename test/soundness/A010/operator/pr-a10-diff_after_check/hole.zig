// precision A010 operator: the unequal check is on another number, so the difference less one underflows where the two are equal
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const a = try r.takeInt(u64, .little);
    const b = try r.takeInt(u64, .little);
    const c = try r.takeInt(u64, .little);
    if (a < b) return 0;
    if (a == c) return 0;
    return a - b - 1;
}
