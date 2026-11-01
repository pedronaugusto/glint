// matrix A012 field: @field names the constant part beside the input
const std = @import("std");
const Header = struct { len: u32, kind: u32 };
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const h: Header = .{ .len = try r.takeInt(u32, .little), .kind = 8 };
    return gpa.alloc(u8, @field(h, "kind"));
}
