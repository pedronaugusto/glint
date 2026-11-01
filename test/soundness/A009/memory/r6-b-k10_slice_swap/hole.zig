// review 6: b/k10_slice_swap.zig
const std = @import("std");
// The slice exchanged with a shorter one through std.mem.swap.
pub fn f(r: *std.Io.Reader, short: []u8) !u8 {
    var memory: [512]u8 = @splat(0);
    var s: []u8 = memory[0..];
    var t = short;
    std.mem.swap([]u8, &s, &t);
    const i: usize = try r.takeInt(u16, .little);
    if (i >= 512) return 0;
    return s[i];
}
