// review 5: p/p06_list_roundtrip.zig
const std = @import("std");
const table: [16]u8 = @splat(0);
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !u8 {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, try r.takeInt(u32, .little));
    return table[list.items[0]];
}
