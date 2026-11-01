// matrix: input written through a for loop's pointer capture, the element then sizes the allocation
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    var sizes: [2]u32 = .{ 0, 0 };
    for (&sizes) |*s| s.* = try r.takeInt(u32, .little);
    return gpa.alloc(u8, sizes[0]);
}
