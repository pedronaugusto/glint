const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u32, .little);
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, n);
    return list.items.len;
}
