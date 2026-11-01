// review 5: p/p01_sort_callback.zig
const std = @import("std");
const table: [16]u8 = @splat(0);
fn less(_: void, a: u32, b: u32) bool {
    return table[a] < table[b];
}
pub fn f(r: *std.Io.Reader) !void {
    var items: [4]u32 = undefined;
    for (&items) |*it| it.* = try r.takeInt(u32, .little);
    std.mem.sort(u32, &items, {}, less);
}
