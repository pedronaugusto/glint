// matrix A009 field: an alias of another type handed to std, the field's own stores only its default
const std = @import("std");
const Config = struct { limit: usize = 0 };
const Other = struct { size: usize = 0 };
const Wire = Other;
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, table: *const [16]u8, c: *const Config) !u8 {
    const text = try r.take(64);
    const o = try std.json.parseFromSliceLeaky(Wire, gpa, text, .{});
    return table[c.limit] +% @as(u8, @truncate(o.size));
}
