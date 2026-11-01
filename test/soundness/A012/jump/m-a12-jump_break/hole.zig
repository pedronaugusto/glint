// matrix A012 jump: a labeled block breaks with input
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = blk: {
        break :blk try r.takeInt(u32, .little);
    };
    return gpa.alloc(u8, n);
}
