// matrix A012 jump: the block reads input but breaks with a constant
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n: u32 = blk: {
        if (try r.takeInt(u32, .little) == 0) break :blk 16;
        break :blk 64;
    };
    return gpa.alloc(u8, n);
}
