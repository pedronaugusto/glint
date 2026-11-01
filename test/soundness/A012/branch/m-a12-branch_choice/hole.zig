// matrix A012 branch: an if expression chooses the input on one side
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, wide: bool) ![]u8 {
    const n: u32 = if (wide) try r.takeInt(u32, .little) else 8;
    return gpa.alloc(u8, n);
}
