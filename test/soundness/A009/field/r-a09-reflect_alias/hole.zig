// matrix A009 field: a type std fills by reflection, handed over under an alias
const std = @import("std");
const Config = struct { limit: usize = 0 };
const Wire = Config;
// Hole: the same type handed to std.json under another name.
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, table: *const [16]u8) !u8 {
    const text = try r.take(64);
    const c = try std.json.parseFromSliceLeaky(Wire, gpa, text, .{});
    return table[c.limit];
}
