// matrix A009 field: a capture of the field by value, which writes nothing
const std = @import("std");
const Config = struct { limit: ?usize = 0 };
pub fn load(r: *std.Io.Reader, c: *Config) !usize {
    const n: usize = try r.takeInt(u32, .little);
    if (c.limit) |v| return v +| n;
    return n;
}
pub fn f(c: *const Config, table: *const [16]u8) u8 {
    return table[c.limit orelse 0];
}
