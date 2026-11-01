// matrix: @min of input and a ceiling sizes the allocation: the ceiling is its limit
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return gpa.alloc(u8, @min(n, 4096));
}
