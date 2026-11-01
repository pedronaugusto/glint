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
