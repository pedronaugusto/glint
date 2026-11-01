// review 5: a19/st06_const_n.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
const n = 4;
pub fn s(words: [4]u64) void {
    var out: [40]u8 = undefined;
    for (0..n) |i| std.mem.writeInt(u64, out[8 * i ..][0..8], words[i], .little);
    use(&out);
}
