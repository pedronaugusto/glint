// review 5: p/p05_binary_search.zig
const std = @import("std");
const table: [16]u8 = @splat(0);
fn order(key: u32, item: u32) std.math.Order {
    return std.math.order(table[key], item);
}
pub fn f(r: *std.Io.Reader, items: []const u32) !?usize {
    const key = try r.takeInt(u32, .little);
    return std.sort.binarySearch(u32, items, key, order);
}
