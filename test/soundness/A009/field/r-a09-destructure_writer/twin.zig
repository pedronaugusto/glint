// matrix A009 field: the field's one writer is a destructure of a constant in the table
const std = @import("std");
const Config = struct { limit: usize = 0 };
pub fn load(r: *std.Io.Reader, c: *Config) !void {
    c.limit, _ = .{ 15, try r.takeInt(u32, .little) };
}
pub fn f(c: *const Config, table: *const [16]u8) u8 {
    return table[c.limit];
}
