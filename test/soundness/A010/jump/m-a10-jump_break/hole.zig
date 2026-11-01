// matrix A010 jump: a labeled block breaks with input, multiplied past its type
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u64 {
    const v = blk: {
        break :blk try r.takeInt(u64, .little);
    };
    return v * 1000;
}
