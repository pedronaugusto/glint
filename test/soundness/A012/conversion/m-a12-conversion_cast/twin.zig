// matrix A012 conversion: input truncated to sixteen bits
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u64, .little);
    return gpa.alloc(u8, @as(u16, @truncate(n)));
}
