const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u32, .little);
    var map: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, n, n);
    return map.count();
}
