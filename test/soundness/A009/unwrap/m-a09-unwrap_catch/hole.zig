// matrix A009 unwrap: an input byte read with a catch default indexes a table
const std = @import("std");
pub fn f(r: *std.Io.Reader, table: *const [16]u8) u8 {
    const i = r.takeByte() catch 0;
    return table[i];
}
