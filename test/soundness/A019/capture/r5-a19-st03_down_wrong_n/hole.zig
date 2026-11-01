// review 5: a19/st03_down_wrong_n.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
pub fn s(words: [4]u64) void {
    var out: [40]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(u64, out[8 * (5 - 1 - i) ..][0..8], words[i], .big);
    use(&out);
}
