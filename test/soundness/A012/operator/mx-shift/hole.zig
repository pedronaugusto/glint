// matrix: input shifted left sizes the allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n: usize = try r.takeInt(u16, .little);
    return gpa.alloc(u8, n << 4);
}
