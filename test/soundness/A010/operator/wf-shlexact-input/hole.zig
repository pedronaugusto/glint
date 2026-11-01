// warp-fast: @shlExact of input: a peer's bits shifted out stop the program
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u32 {
    const a = try r.takeInt(u32, .little);
    return @shlExact(a, 4);
}
