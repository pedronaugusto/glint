// glint-b: std.math.divCeil read at this call's binding (usize): a divisor at least 1 rules out each failing exit
const std = @import("std");
pub fn tiles(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return std.math.divCeil(usize, in.len, @as(usize, in[1]) + 1) catch unreachable;
}
