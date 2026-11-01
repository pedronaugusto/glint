// review 5: a19/st04_under_if.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
pub fn s(words: [4]u64, c: bool) void {
    var out: [32]u8 = undefined;
    if (c) for (0..4) |i| std.mem.writeInt(u64, out[8 * i ..][0..8], words[i], .little);
    use(&out);
}
