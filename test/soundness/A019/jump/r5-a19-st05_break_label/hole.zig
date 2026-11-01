// review 5: a19/st05_break_label.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
pub fn s(words: [4]u64) void {
    var out: [32]u8 = undefined;
    blk: {
        if (words[0] == 0) break :blk;
        for (0..4) |i| std.mem.writeInt(u64, out[8 * i ..][0..8], words[i], .little);
    }
    use(&out);
}
