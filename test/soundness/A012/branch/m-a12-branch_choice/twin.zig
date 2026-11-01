// matrix A012 branch: input decides between two constants
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n: u32 = if (try r.takeInt(u32, .little) > 10) 64 else 8;
    return gpa.alloc(u8, n);
}
