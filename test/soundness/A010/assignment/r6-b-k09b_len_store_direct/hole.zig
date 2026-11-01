// review 6: b/k09b_len_store_direct.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    var memory: [512]u8 = @splat(0);
    var s: []u8 = memory[0..];
    const n: usize = try r.takeInt(u64, .little);
    s.len = n;
    return s.len - 86;
}
