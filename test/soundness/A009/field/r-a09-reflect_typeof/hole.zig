// matrix A009 field: a type std fills by reflection, handed over as @TypeOf a value
const std = @import("std");
const Config = struct { limit: usize = 0 };
// Hole: the type handed to std.json as @TypeOf a value.
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, table: *const [16]u8, seed: Config) !u8 {
    const text = try r.take(64);
    const c = try std.json.parseFromSliceLeaky(@TypeOf(seed), gpa, text, .{});
    return table[c.limit];
}
