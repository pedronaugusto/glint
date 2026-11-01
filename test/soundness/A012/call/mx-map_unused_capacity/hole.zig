// matrix: std's hash map grown by a count from input, through a size parameter named additional_size
const std = @import("std");
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u32, u32)) !void {
    const n = try r.takeInt(u32, .little);
    try map.ensureUnusedCapacity(gpa, n);
}
