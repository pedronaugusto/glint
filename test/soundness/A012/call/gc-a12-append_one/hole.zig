// glint-c: a list grown by a count from input
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u32, .little);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendNTimes(gpa, 0, n);
    return list.items.len;
}
