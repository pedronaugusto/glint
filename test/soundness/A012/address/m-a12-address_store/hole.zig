// matrix A012 address: input written through a pointer to the size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    const p = &n;
    p.* = try r.takeInt(u32, .little);
    return gpa.alloc(u8, n);
}
