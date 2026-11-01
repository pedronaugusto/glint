// warp-fast: a u24 shifted by an amount from input: its amount type (u5) holds 24..31, past its width
const std = @import("std");
pub fn f(r: *std.Io.Reader, x: u24) !u24 {
    const n: u5 = @truncate(try r.takeByte());
    return x << n;
}
