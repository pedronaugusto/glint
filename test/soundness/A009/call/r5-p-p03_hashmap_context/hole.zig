// review 5: p/p03_hashmap_context.zig
const std = @import("std");
const table: [16]u64 = @splat(0);
const Ctx = struct {
    pub fn hash(_: Ctx, k: u32) u64 {
        return table[k];
    }
    pub fn eql(_: Ctx, a: u32, b: u32) bool {
        return a == b;
    }
};
pub fn f(gpa: std.mem.Allocator, r: *std.Io.Reader) !void {
    var map: std.HashMapUnmanaged(u32, void, Ctx, 80) = .empty;
    defer map.deinit(gpa);
    try map.put(gpa, try r.takeInt(u32, .little), {});
}
