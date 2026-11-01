// review 5: b/b03_slicelen_store.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !usize {
    var memory: [512]u8 = @splat(0);
    var s: []u8 = memory[0..];
    const n: usize = try r.takeInt(u64, .little);
    s.len = n;
    return s.len - 86;
}
