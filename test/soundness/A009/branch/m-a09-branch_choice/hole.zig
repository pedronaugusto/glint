// matrix A009 branch: an if expression chooses the input on one side
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8, wide: bool) !u8 {
    const i: u8 = if (wide) try r.takeByte() else 0;
    return table[i];
}
