// matrix A009 branch: input decides between two indexes in range
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8) !u8 {
    const i: u8 = if (try r.takeByte() > 10) 3 else 4;
    return table[i];
}
