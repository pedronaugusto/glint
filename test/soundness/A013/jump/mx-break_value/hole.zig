// matrix: a labeled block breaks with input, asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const kind = blk: {
        break :blk try r.takeByte();
    };
    std.debug.assert(kind < 4);
    return kind;
}
