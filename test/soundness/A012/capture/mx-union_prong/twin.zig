// matrix: a switch prong's capture of a union's payload, input, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
const Frame = union(enum) { data: u32, ping };
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const frame: Frame = if (try r.takeByte() == 0) .ping else .{ .data = try r.takeInt(u32, .little) };
    return switch (frame) {
        .data => |len| {
            try limit.check(len);
            return gpa.alloc(u8, len);
        },
        .ping => gpa.alloc(u8, 0),
    };
}
