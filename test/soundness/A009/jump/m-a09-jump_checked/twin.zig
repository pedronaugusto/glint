// matrix A009 jump: a labeled block breaks with an index it checked
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const i = blk: {
        const b = try r.takeByte();
        if (b >= table.len) return error.Range;
        break :blk b;
    };
    return table[i];
}
