// c1: after before.zig, an allocation of a constant size
const std = @import("std");
pub fn g(gpa: std.mem.Allocator) ![]u8 {
    return gpa.alloc(u8, 16);
}
