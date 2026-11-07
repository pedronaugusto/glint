const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u8, .little);
    const bytes = try r.take(n);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, bytes);
    return list.items.len;
}
