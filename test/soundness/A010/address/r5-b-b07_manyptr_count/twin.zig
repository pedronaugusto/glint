// review 5: b/b07_manyptr_count.zig
const std = @import("std");
pub fn f(r: *std.Io.Reader, p: [*]const u8) !u8 {
    const n: usize = try r.takeInt(u32, .little);
    const s = p[0..n];
    var acc: u8 = 0;
    for (0..n) |i| acc +%= s[i];
    return acc;
}
