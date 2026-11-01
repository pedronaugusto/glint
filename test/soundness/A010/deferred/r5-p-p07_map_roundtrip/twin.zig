// review 5: p/p07_map_roundtrip.zig
const std = @import("std");
const table: [16]u8 = @splat(0);
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !u8 {
    var map: std.AutoHashMapUnmanaged(u8, u32) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, 1, try r.takeInt(u32, .little));
    return table[map.get(1).?];
}
