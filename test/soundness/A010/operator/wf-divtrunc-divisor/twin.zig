// warp-fast: @divTrunc of input by a constant divisor: never zero
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const a = try r.takeInt(u32, .little);
    return @divTrunc(a, 7);
}
