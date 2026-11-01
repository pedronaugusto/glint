// matrix: std's hash map grown by a count from input checked against aegis's Limit first
const std = @import("std");
const aegis = @import("aegis");
const limit: aegis.bounded.Limit(u64) = .init(4096);
pub fn f(r: *std.Io.Reader, gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u32, u32)) !void {
    const n = try r.takeInt(u32, .little);
    try limit.check(n);
    try map.ensureUnusedCapacity(gpa, n);
}
