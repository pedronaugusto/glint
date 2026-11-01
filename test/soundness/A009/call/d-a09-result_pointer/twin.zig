// matrix A009 call: a constant stored through that pointer
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, table: *const [16]u8) !u8 {
    var list: std.ArrayList(usize) = .empty;
    const p = try list.addOne(gpa);
    p.* = 3;
    _ = try r.takeInt(u32, .little);
    return table[list.items[0]];
}
