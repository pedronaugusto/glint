// review 5: b/b06e_count_shrinks_idx.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, big: []const u8) !u8 {
    var s = big;
    var acc: u8 = 0;
    const n: usize = try r.takeInt(u32, .little);
    for (s, 0..) |_, i| {
        if (n == i) acc +%= s[n];
        s = s[1..];
    }
    return acc;
}
