// review 6: b/k11b_slice_set_direct.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    var memory: [512]u8 = @splat(0);
    var s: []u8 = memory[0..];
    s = s[0..1];
    const i: usize = try r.takeInt(u16, .little);
    if (i >= 512) return 0;
    return s[i];
}
