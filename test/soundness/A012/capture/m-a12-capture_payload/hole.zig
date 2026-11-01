// matrix A012 capture: an if's payload, input, sizes the allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const maybe: ?u32 = try r.takeInt(u32, .little);
    if (maybe) |n| return gpa.alloc(u8, n);
    return error.Missing;
}
