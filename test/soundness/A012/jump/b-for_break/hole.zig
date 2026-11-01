// matrix A012 jump: a for breaks with input, its value the size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n: u32 = for (0..3) |_| {
        const v = try r.takeInt(u32, .little);
        if (v != 0) break v;
    } else 16;
    return gpa.alloc(u8, n);
}
