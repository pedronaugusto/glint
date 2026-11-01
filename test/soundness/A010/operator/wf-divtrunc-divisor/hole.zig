// warp-fast: @divTrunc by a divisor from input: a peer's zero stops the program
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const a = try r.takeInt(u32, .little);
    const b = try r.takeInt(u32, .little);
    return @divTrunc(a, b);
}
