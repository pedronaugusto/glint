// matrix: an inline for over a header's fields sums them by @field, input among them, into the size
const std = @import("std");
const Header = struct { head: u32, body: u32 };
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const h: Header = .{ .head = 8, .body = try r.takeInt(u32, .little) };
    var n: usize = 0;
    inline for (@typeInfo(Header).@"struct".field_names) |name| n += @field(h, name);
    return gpa.alloc(u8, n);
}
