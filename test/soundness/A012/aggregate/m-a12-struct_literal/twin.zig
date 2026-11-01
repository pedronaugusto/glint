// matrix A012 aggregate: the field that sizes the allocation is the literal's constant one
const std = @import("std");
const Sizes = struct { head: u32, body: u32 };
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const s: Sizes = .{ .head = 8, .body = try r.takeInt(u32, .little) };
    return gpa.alloc(u8, s.head);
}
