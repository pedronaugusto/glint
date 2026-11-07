const std = @import("std");
pub fn f(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged(u32), r: *std.Io.Reader) !void {
    const n = try r.takeInt(u32, .little);
    try map.put(gpa, "k", n);
    map.deinit(gpa);
}
