// matrix: @field with a name held in a constant reads the part input sized, checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
const Header = struct { len: u32, kind: u32 };
const size_field = "len";
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    const h: Header = .{ .len = try r.takeInt(u32, .little), .kind = 8 };
    try limit.check(@field(h, size_field));
    return gpa.alloc(u8, @field(h, size_field));
}
