// matrix A012 aggregate: a struct literal holds input in the field that sizes the allocation
const std = @import("std");
const Sizes = struct { head: u32, body: u32 };
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const s: Sizes = .{ .head = 8, .body = try r.takeInt(u32, .little) };
    return gpa.alloc(u8, s.body);
}
