// glint-b: std.math.divCeil read at this call's binding (usize): a divisor a peer's byte may make zero fails
const std = @import("std");
pub fn tiles(r: *std.Io.Reader) !usize {
    const in = try r.take(8);
    return std.math.divCeil(usize, in.len, in[1]) catch unreachable;
}
