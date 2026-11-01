// review 5: a19/st07_range_start.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
pub fn s(words: [5]u64) void {
    var out: [32]u8 = undefined;
    for (1..5) |i| std.mem.writeInt(u64, out[8 * (i - 1) ..][0..8], words[i], .little);
    use(&out);
}
