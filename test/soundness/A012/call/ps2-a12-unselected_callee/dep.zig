const std = @import("std");
pub fn grab(gpa: std.mem.Allocator, n: usize) ![]u8 {
    return gpa.alloc(u8, n);
}
