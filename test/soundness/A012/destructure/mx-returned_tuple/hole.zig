// matrix: the part destructured from a helper's returned tuple, read from input, sizes the allocation
const std = @import("std");
fn header(r: *std.Io.Reader) !struct { u32, u8 } {
    return .{ try r.takeInt(u32, .little), 1 };
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const len, const kind = try header(r);
    _ = kind;
    return gpa.alloc(u8, len);
}
