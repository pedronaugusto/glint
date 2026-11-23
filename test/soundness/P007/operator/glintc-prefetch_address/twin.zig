// P007: an address into a many-item pointer's memory given only to @prefetch, a cache hint
// that reads and writes nothing (warp's hash tables).
pub fn f(table: [*]u32, h: usize, bucket: []u32) void {
    @prefetch(&table[h], .{ .rw = .write });
    @prefetch(bucket.ptr + 16, .{});
}
