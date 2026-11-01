// warp-fast: @shlWithOverflow of a u24 by an amount from input: past its width stops the program
const std = @import("std");
pub fn f(r: *std.Io.Reader, x: u24) !u24 {
    const n: u5 = @truncate(try r.takeByte());
    return @shlWithOverflow(x, n)[0];
}
