// review 5: b/b24_lenfield_table.zig
const std = @import("std");
const Header = struct { len: u32 };
const table = [16]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
pub fn f(r: *std.Io.Reader) !u8 {
    const h: Header = .{ .len = try r.takeInt(u32, .little) };
    return table[h.len];
}
