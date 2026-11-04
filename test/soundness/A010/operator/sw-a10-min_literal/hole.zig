// A010: @min with a comptime 255 is a u8 (Zig narrows @min to what its operands bound), so the step past it overflows
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const b = try r.takeInt(u64, .little);
    var n = @min(b, 255);
    n += 1;
    return n;
}
