// matrix A009 field: the field's one writer is a pointer capture
const std = @import("std");
const Config = struct { limit: ?usize = 0 };
pub fn load(r: *std.Io.Reader, c: *Config) !void {
    const n: usize = try r.takeInt(u32, .little);
    if (c.limit) |*p| p.* = n;
}
// Hole: the field's one writer is a pointer capture.
pub fn f(c: *const Config, table: *const [16]u8) u8 {
    return table[c.limit orelse 0];
}
