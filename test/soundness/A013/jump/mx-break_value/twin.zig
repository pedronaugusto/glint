// matrix: a labeled block reads input but breaks with a constant, asserted
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const kind: u8 = blk: {
        _ = try r.takeByte();
        break :blk 3;
    };
    std.debug.assert(kind < 4);
    return kind;
}
