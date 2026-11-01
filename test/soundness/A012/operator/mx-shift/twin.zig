// matrix: input shifted right by its whole width sizes the allocation: nothing of it is left
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n: u8 = try r.takeByte();
    return gpa.alloc(u8, @as(usize, n >> 7) + 8);
}
