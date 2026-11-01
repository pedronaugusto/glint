// matrix: a switch prong's capture of a union's payload, input, sizes the allocation
const std = @import("std");
const Frame = union(enum) { data: u32, ping };
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const frame: Frame = if (try r.takeByte() == 0) .ping else .{ .data = try r.takeInt(u32, .little) };
    return switch (frame) {
        .data => |len| gpa.alloc(u8, len),
        .ping => gpa.alloc(u8, 0),
    };
}
