// glint-c: a list grown by one element of the program's own, beside a number from input
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u32, .little);
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 7);
    return list.items.len + @min(n, 1);
}
