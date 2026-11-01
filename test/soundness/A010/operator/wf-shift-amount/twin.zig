// warp-fast: a u32 shifted by an amount from input: its amount type (u5) holds only amounts below 32
const std = @import("std");
pub fn f(r: *std.Io.Reader, x: u32) !u32 {
    const n: u5 = @truncate(try r.takeByte());
    return x << n;
}
