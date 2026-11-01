// warp-fast: @divExact of input: a peer's remainder stops the program
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const a = try r.takeInt(u32, .little);
    return @divExact(a, 4);
}
