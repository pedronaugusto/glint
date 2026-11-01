// warp-fast: @shlWithOverflow of a u32 by an amount from input: its u5 amount is always below 32
const std = @import("std");
pub fn f(r: *std.Io.Reader, x: u32) !u32 {
    const n: u5 = @truncate(try r.takeByte());
    return @shlWithOverflow(x, n)[0];
}
