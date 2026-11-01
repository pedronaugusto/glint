// matrix: std's alloc called through @call with a size from input
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const n = try r.takeInt(u32, .little);
    return @call(.auto, std.mem.Allocator.alloc, .{ gpa, u8, n });
}
