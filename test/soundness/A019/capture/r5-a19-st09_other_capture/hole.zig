// review 5: a19/st09_other_capture.zig
const std = @import("std");
fn use(b: []const u8) void {
    _ = b;
}
pub fn s(words: [4]u64) void {
    var out: [32]u8 = undefined;
    for (0..4, 0..) |_, j| std.mem.writeInt(u64, out[8 * j ..][0..8], words[j], .little);
    use(&out);
}
