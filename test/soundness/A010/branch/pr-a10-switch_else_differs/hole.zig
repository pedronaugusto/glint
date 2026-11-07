// precision A010 branch: the switch is on another number, so the else prong's difference underflows
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const n = try r.takeInt(u64, .little);
    const m = try r.takeInt(u64, .little);
    return switch (m) {
        0, 1 => 0,
        else => n - 2,
    };
}
