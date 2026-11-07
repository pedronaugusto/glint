const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator) !usize {
    const n = try r.takeInt(u32, .little);
    var map: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, n, {});
    return map.count();
}
