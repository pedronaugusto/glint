// matrix A012 address: what is written through the pointer is limited
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var n: u32 = 0;
    const p = &n;
    const m = try r.takeInt(u32, .little);
    if (m > 4096) return error.TooLarge;
    p.* = m;
    return gpa.alloc(u8, n);
}
