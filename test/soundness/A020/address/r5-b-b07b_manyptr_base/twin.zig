// review 5: b/b07b_manyptr_base.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader) !u8 {
    const n: usize = try r.takeInt(u32, .little);
    var acc: u8 = 0;
    for (0..n) |i| acc +%= @truncate(i);
    return acc;
}
