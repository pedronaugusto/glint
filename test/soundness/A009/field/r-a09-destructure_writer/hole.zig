// matrix A009 field: the field's one writer is a destructure of input
const std = @import("std");
const Config = struct { limit: usize = 0 };
pub fn load(r: *std.Io.Reader, c: *Config) !void {
    c.limit, _ = .{ try r.takeInt(u32, .little), 0 };
}
// Hole: the field's one writer is a destructure; Range reads it as only ever 0.
pub fn f(c: *const Config, table: *const [16]u8) u8 {
    return table[c.limit];
}
