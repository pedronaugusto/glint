// matrix A009 field: a constant stored in the field through such a holder
const std = @import("std");
const Config = struct { limit: usize = 0 };
pub fn load(r: *std.Io.Reader, holder: anytype) !void {
    holder.limit = 3;
    _ = try r.takeInt(u32, .little);
}
pub fn f(c: *const Config, table: *const [16]u8) u8 {
    return table[c.limit];
}

/// A binding: the ruling's remedy for a public generic nothing else binds.
pub fn loadConfig(r: *std.Io.Reader, c: *Config) !void {
    try load(r, c);
}
