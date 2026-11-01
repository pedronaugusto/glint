// matrix A012 operator: input plus a header's size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n + 8);
}
