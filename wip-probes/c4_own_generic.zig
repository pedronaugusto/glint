const std = @import("std");
fn Box(comptime T: type) type {
    return struct {
        items: std.ArrayList(T) = .empty,
        const Self = @This();
        fn add(self: *Self, gpa: std.mem.Allocator, x: T) !void {
            try self.items.append(gpa, x);
        }
    };
}
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u32, .little);
    var box: Box(u32) = .{};
    defer box.items.deinit(gpa);
    try box.add(gpa, n);
    return box.items.items.len;
}
