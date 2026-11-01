// matrix A012 capture: the payload is limited before it sizes the allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const maybe: ?u32 = try r.takeInt(u32, .little);
    if (maybe) |n| {
        if (n > 4096) return error.TooLarge;
        return gpa.alloc(u8, n);
    }
    return error.Missing;
}
