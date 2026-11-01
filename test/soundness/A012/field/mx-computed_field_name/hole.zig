// matrix: @field with a name held in a constant reads the part input sized
const std = @import("std");
const Header = struct { len: u32, kind: u32 };
const size_field = "len";
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const h: Header = .{ .len = try r.takeInt(u32, .little), .kind = 8 };
    return gpa.alloc(u8, @field(h, size_field));
}
